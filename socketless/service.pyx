# -*- Mode: Python; tab-width: 4; indent-tabs-mode: nil; -*-

import logging

from syncless import coio
from syncless.util import Queue

from socketless.channelserver import ChannelServer
from socketless.channel cimport Channel
from socketless.channel import DisconnectedException, Channel
from socketless.messenger import Messenger, invoke_all

from serialize cimport MessageReader
from serialize import MessageReader, MarshallerGenerator

class Method(object):
    """docstring for Method"""
    def __init__(self, signature, input, output):
        super(Method, self).__init__()
        self.signature = signature
        self.input_parameters = input
        self.output_parameters = output

class Protocol(object):
    """docstring for Protocol"""
    def __init__(self):
        super(Protocol, self).__init__()

cdef class Service(object):
    cdef object marshaller_generator
    cdef object _protocol
    cdef dict implementations
    cdef dict bindings

    """docstring for Service"""
    def __init__(_self, _protocol, _marshaller_generator=MarshallerGenerator(), **implementations):
        super(Service, _self).__init__()
        _self.marshaller_generator = _marshaller_generator
        _self.protocol = _protocol
        _self.implementations = implementations
        _self.bindings = dict((method.signature, _self.create_binding(method, implementations[name])) for name, method in _self.protocol.methods.iteritems())

    def create_binding(self, method, implementation):
        marshal_input, unmarshal_input = self.marshaller_generator.compile(method.input_parameters)
        marshal_output, unmarshal_output = self.marshaller_generator.compile(method.output_parameters)
        if len(method.input_parameters) == 0:
            if len(method.output_parameters) < 2:
                def binding(reader):
                    return marshal_output(implementation())
            else:
                def binding(reader):
                    return marshal_output(*implementation())
        elif len(method.input_parameters) == 1:
            if len(method.output_parameters) < 2:
                def binding(reader):
                    return marshal_output(implementation(unmarshal_input(reader)))
            else:
                def binding(reader):
                    return marshal_output(*implementation(unmarshal_input(reader)))
        else:
            if len(method.output_parameters) < 2:
                def binding(reader):
                    return marshal_output(implementation(*unmarshal_input(reader)))
            else:
                def binding(reader):
                    return marshal_output(*implementation(*unmarshal_input(reader)))
        return binding

    cpdef _flush_loop(self, Channel channel, flush_queue):
        try:
            while True:
                flush_queue.popleft()
                channel.flush()
        except DisconnectedException:
            pass

    cpdef handle_connection(self, Channel channel):
        cdef MessageReader reader
        flush_queue = Queue()
        flusher = coio.stackless.tasklet(self._flush_loop)(channel, flush_queue)
        try:
            while True:
                message = channel.recv()
                reader = MessageReader(message)
                signature = reader.read(1)
                binding = self.bindings[signature]
                response = binding(reader)
                channel.send(response)
                if len(flush_queue) == 0:
                    flush_queue.append(True)
        finally:
            flusher.kill()


class ServiceServer(object):
    """docstring for ServiceServer"""
    def __init__(self, listener, services):
        super(ServiceServer, self).__init__()
        self.services = dict((service.protocol.handshake[0], service) for service in services)
        self.listener = listener
        self.channel_server = ChannelServer(self.listener, handle_connection=self.handle_connection)

    def handshake(self, channel):
        logging.debug('Awaiting challenge.')
        challenge = channel.recv()
        logging.debug('Got challenge: "%s"', challenge)
        service = self.services.get(challenge, None)
        if not service:
            logging.warning('Failed handshake!')
            return None
        response = service.protocol.handshake[1]
        logging.debug('Correct challenge, sending response: "%s"', response)
        channel.send(response)
        channel.flush()
        logging.debug('Succesfully completed handshake.')
        return service

    def handle_connection(self, channel, addr):
        try:
            service = self.handshake(channel)
            if service:
                service.handle_connection(channel)
        except DisconnectedException:
            logging.info('client %s disconnected', addr)
        except BaseException, e:
            logging.exception(e)
        finally:
            try:
                channel.close()
            except DisconnectedException, e:
                pass

    def serve(self):
        logging.info("Listening on %s", self.listener)
        self.channel_server.serve()

    def stop(self):
        self.channel_server.stop()

class ServiceClient(object):
    """docstring for ServiceClient"""
    def __init__(self, listener, protocol, marshaller_generator=MarshallerGenerator()):
        super(ServiceClient, self).__init__()
        self.listener = listener
        self.protocol = protocol
        self.marshaller_generator = marshaller_generator
        self.messenger = Messenger(listener, handshake=self.protocol.handshake)
        for name, method in protocol.methods.iteritems():
            setattr(self, name, self._create_binding(method))

    def _create_binding(self, method):
        marshal_input, unmarshal_input = self.marshaller_generator.compile(method.input_parameters)
        marshal_output, unmarshal_output = self.marshaller_generator.compile(method.output_parameters)
        signature = method.signature
        token = id(self.messenger)
        messengers = [(token, self.messenger)]
        def binding(*args):
            [(reply, reply_token)] = invoke_all((signature,) + marshal_input(*args), messengers)
            return None if reply is None else unmarshal_output(MessageReader(reply))
        return binding

    def is_connected(self):
        return self.messenger.connected if self.messenger else False

    def close(self):
        if self.messenger:
            self.messenger.close()
            self.messenger = None

class MultiServiceClient:
    """docstring for MultiServiceClient"""
    def __init__(self, clients, protocol, marshaller_generator=MarshallerGenerator()):
        self.protocol = protocol
        self.marshaller_generator = marshaller_generator
        for name, method in protocol.methods.iteritems():
            setattr(self, name, self.__create_binding(method))
        self.update_clients(clients)

    def update_clients(self, clients):
        self.clients = clients
        self.messengers = [(client, client.messenger) for client in self.clients]

    def __create_binding(self, method):
        marshal_input, unmarshal_input = self.marshaller_generator.compile(method.input_parameters)
        marshal_output, unmarshal_output = self.marshaller_generator.compile(method.output_parameters)
        signature = method.signature
        def binding(*args):
            replies = invoke_all((signature,) + marshal_input(*args), self.messengers)
            return [(token, None if reply is None else unmarshal_output(MessageReader(reply))) for reply, token in replies]
        return binding

    def is_connected(self):
        if not self.clients:
            return False
        for messenger in self.messengers:
            if not messenger.connected:
                return False
        return True
