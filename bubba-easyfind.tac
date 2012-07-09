#!/usr/bin/python
import ConfigParser
import codecs
import json
import urllib
from cStringIO import StringIO

from configobj import ConfigObj
from twisted.application import service
from twisted.application.internet import TimerService
from twisted.internet import reactor, defer
from twisted.internet.defer import succeed, Deferred
from twisted.internet.protocol import Protocol
from twisted.python import log
from twisted.web.client import Agent, ResponseDone
from twisted.web.http import PotentialDataLoss
from twisted.web.http_headers import Headers
from twisted.web.iweb import IBodyProducer
from validate import Validator
from zope.interface import implements


LOOP_TIMEOUT = 1  # in seconds the wait time until next query


class StringProducer(object):
    implements(IBodyProducer)

    def __init__(self, body):
        self.body = body
        self.length = len(body)

    def startProducing(self, consumer):
        consumer.write(self.body)
        return succeed(None)

    def pauseProducing(self):
        pass

    def stopProducing(self):
        pass


class StringReceiver(Protocol):
    def __init__(self):
        self.string_io = codecs.getwriter('utf_8')(StringIO())
        self.deferred = Deferred()

    def dataReceived(self, bytes):
        self.string_io.write(bytes)

    def connectionLost(self, reason):
        if reason.check(ResponseDone) or reason.check(PotentialDataLoss):
            self.deferred.callback(self.string_io.getvalue())
        else:
            self.deferred.errback(reason)


def httpRequest(url, values={}, headers={}, method='POST', timeout=10):
    # Construct an Agent.
    agent = Agent(reactor, connectTimeout=timeout)
    data = urllib.urlencode(values)

    d = agent.request(method,
                      url,
                      Headers(headers),
                      StringProducer(data) if data else None)

    def handle_response(response):
        if response.code == 204:
            return defer.succeed('')
        else:
            string_reciever = StringReceiver()
            response.deliverBody(string_reciever)
            return string_reciever.deferred

    def handle_error(error):
        log.err(error)
    d.addCallback(handle_response)
    d.addErrback(handle_error)
    return d

spec = """
    name = string(default="")
    ip = string(default="127.0.0.1")
    enabled = boolean(default=False)
"""

application = service.Application("Easyfind Update Service")
config = ConfigObj('/etc/network/easyfind.conf', configspec=spec.split("\n"))
validator = Validator()
config.validate(validator, copy=True)
try:
    config.write()
except IOError:
    log.err("unable to write easyfind config")

old_ip = config['ip']
enabled = config['enabled']
name = config['name']


def easyfind_ip_changed(data):
    global old_ip, enabled
    if not enabled:
        return
    try:
        decoded = json.loads(data)
        if 'ip_address' in decoded:
            new_ip = decoded['ip_address']
            if old_ip is not new_ip:
                log.msg("Got new IP '%s' which is not the same as the last one '%s'" % (new_ip, old_ip))
                easyfind_set_ip(new_ip)
            else:
                old_ip = new_ip
                log.msg("Got new IP '%s' which is the same as the last one '%s'" % (new_ip, old_ip))
    except TypeError as e:
        log.err(e)
        log.err("Failed to decode as JSON: \"%s\"" % data)


def easyfind_ip_updated():
    pass


def parse_cmdline():

    cmdline = (open("/proc/cmdline", "r").read())
    return dict(token.split('=', 1) if token.count("=") else (token, True) for token in cmdline.split(" "))


def easyfind_set_ip(new_ip):
    global old_ip
    cmdline = parse_cmdline()
    log.msg(cmdline)
    try:
        key = cmdline['key']
    except KeyError:
        log.err("Unable to retrieve secret key from system")
        return

    old_ip = new_ip
    log.msg(key)
    config = ConfigParser.RawConfigParser()
    config.read('/etc/network/easyfind.conf')

    config['ip'] = new_ip

    config.write_empty_values = True

    try:
        config.write()
    except IOError:
        log.err("unable to write easyfind config")

    d = httpRequest(
        "http://79.125.123.89/domain.json",
        {
            'key': key,
            'ip': new_ip,
            'name': config['name']
        },
        method='POST',
        headers={'Content-Type': ['application/json']},
        timeout=2
    )
    d.addCallback(easyfind_ip_updated)
    d.addErrback(err)


def err(reason):
        log.err(reason)


def check_easyfind():
    d = httpRequest(
        "http://79.125.123.89/ip.json",
        method='GET',
        headers={'Content-Type': ['application/json']},
        timeout=2
    )
    d.addCallback(easyfind_ip_changed)
    d.addErrback(err)

ts = TimerService(LOOP_TIMEOUT, check_easyfind)
ts.setServiceParent(application)
