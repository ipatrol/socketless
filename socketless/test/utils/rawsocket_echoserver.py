from syncless.util import Queue
from syncless import coio

import paths

from socketless.channel import Channel, DisconnectedException
from socketless.streamserver import StreamServer
import rawsocket_echoserver_core

class EchoServer(StreamServer):
	"""docstring for Handler"""
	def __init__(self, listener):
		super(EchoServer, self).__init__(listener)
		print 'started'

	def handle_connection(self, s, address):
		print 'New connection from %s:%s' % address
		try:
			c = Channel(s)
			rawsocket_echoserver_core.receiver(c)
			c.close()
		except DisconnectedException:
			print 'Client disconnected'

def main():
	EchoServer(('127.0.0.1', 5555))

if __name__ == '__main__':
	main()