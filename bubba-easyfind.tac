#!/usr/bin/python
import codecs
import json
import urllib
from cStringIO import StringIO

from twisted.application import service
from twisted.application.internet import TimerService
from twisted.internet import reactor, defer
from twisted.internet.defer import succeed, Deferred
from twisted.internet.protocol import Protocol
from twisted.web.client import Agent, ResponseDone, ResponseFailed
from twisted.web.http import PotentialDataLoss
from twisted.web.http_headers import Headers
from twisted.web.iweb import IBodyProducer
from zope.interface import implements


LOOP_TIMEOUT = 0.01  # in seconds the wait time until next query


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


def httpRequest(url, values={}, headers={}, method='POST'):
    # Construct an Agent.
    agent = Agent(reactor)
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

    d.addCallback(handle_response)
    return d


application = service.Application("Easyfind Update Service")


def easyfind_ip_changed(data):
    decoded = json.loads(data)
    # TODO check if IP has changed, and if changed, call easyfind_set_ip(new_ip)
    print decoded['ip_address']


def easyfind_set_ip():
    # TODO implement
    pass

def err(reason):
    if reason.check(ResponseFailed):
        print reason.getErrorMessage()

def check_easyfind():
    d = httpRequest(
        "http://79.125.123.89/ip.json",
    method='GET',
    headers={'Content-Type': ['application/json']}
    )
    d.addCallback(easyfind_ip_changed)
    d.addErrback(err)

ts = TimerService(LOOP_TIMEOUT, check_easyfind)
ts.setServiceParent(application)
