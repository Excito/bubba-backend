#!/usr/bin/python
import codecs
import json
import urllib
import netifaces
import subprocess
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


LOOP_TIMEOUT = 60  # in seconds the wait time until next query


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
        pass
    d.addCallback(handle_response)
    d.addErrback(handle_error)
    return d

spec = """
    name = string(default="")
    ip = string(default="127.0.0.1")
    enable = boolean(default=False)
"""

application = service.Application("Easyfind Update Service")
config = ConfigObj('/etc/network/easyfind.conf', configspec=spec.split("\n"))
validator = Validator()
config.validate(validator, copy=True)
try:
    config.write()
except IOError:
    log.err("unable to write easyfind config")


def easyfind_ip_changed(data):
    try:
        decoded = json.loads(data)
        if 'ip_address' in decoded:
            new_ip = decoded['ip_address']
            if config['ip'] != new_ip:
                log.msg("Got new IP '%s' which is not the same as the last one '%s'" % (new_ip, config['ip']))
                easyfind_set_ip(new_ip)
            else:
                log.msg("Got new IP '%s' which is the same as the last one '%s'" % (new_ip, config['ip']))
    except TypeError:
        # ignore any errors
        pass


def easyfind_ip_updated(response):
    pass


def parse_cmdline():
    return dict(token.split('=', 1) if token.count("=") else (token, True) for token in open("/proc/cmdline", "r").read().split(" "))


def easyfind_set_ip(new_ip):
    cmdline = parse_cmdline()
    try:
        key = cmdline['key']
    except KeyError:
        log.err("Unable to retrieve secret key from system")
        return

    config['ip'] = new_ip

    config.write_empty_values = True

    try:
        config.write()
    except IOError:
        log.err("unable to write easyfind config")

    # current WAN interface
    WAN = subprocess.Popen(
        ['bubba-networkmanager-cli', 'getwanif'],
        stdout=subprocess.PIPE
    ).communicate()[0].strip()

    interface = netifaces.ifaddresses(WAN)
    if netifaces.AF_LINK in interface:
        mac0 = interface[netifaces.AF_LINK][0]['addr']
    d = httpRequest(
        "https://easyfind.excito.org",
        {
            'key': key,
            'mac0': mac0,
        },
        method='POST',
        headers={'Content-Type': ['application/x-www-form-urlencoded']}
    )
    d.addCallback(easyfind_ip_updated)
    d.addErrback(err)


def err(reason):
        log.err(reason)


def check_easyfind():
    config.reload()
    config.validate(validator)
    if not config['enable']:
        return
    d = httpRequest(
        "http://ef.excito.org/ip.json",
        method='GET',
        headers={'Content-Type': ['application/json']},
        timeout=2
    )
    d.addCallback(easyfind_ip_changed)
    d.addErrback(err)

ts = TimerService(LOOP_TIMEOUT, check_easyfind)
ts.setServiceParent(application)
