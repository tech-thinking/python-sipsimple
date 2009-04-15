#!/usr/bin/env python
# Copyright (C) 2008-2009 AG Projects. See LICENSE for details.
#

from __future__ import with_statement
from contextlib import contextmanager
import sys
import os
import datetime
import time
from optparse import OptionParser
from twisted.internet.error import ConnectionClosed
from application.notification import NotificationCenter, IObserver, Any
from application import log
from application.python.util import Singleton
from zope.interface import implements

from eventlet import api, proc
from eventlet.green.socket import gethostbyname
from msrplib import trafficlog

from sipsimple.core import SIPURI, SIPCoreError
from sipsimple.clients.console import setup_console, CTRL_D, EOF
from sipsimple.clients.log import Logger
from sipsimple.green.core import GreenEngine, InvitationError
from sipsimple.green.sessionold import make_SDPMedia
from sipsimple.session2 import Session as GreenSession
from sipsimple.green.notification import linked_notification, linked_notifications
from sipsimple import util
from sipsimple.session import SessionManager, SessionStateError
from sipsimple.clients.clientconfig import get_path
from sipsimple.clients import format_cmdline_uri
from sipsimple import logstate
from sipsimple.green.notification import NotifyFromThreadObserver
from sipsimple.configuration.settings import SIPSimpleSettings
from sipsimple.account import AccountManager, BonjourAccount
from sipsimple.configuration import ConfigurationManager
from sipsimple.configuration.backend.configfile import ConfigFileBackend
from sipsimple.clients.dns_lookup import lookup_routes_for_sip_uri, lookup_service_for_sip_uri
from sipsimple.msrp import LoggerSingleton
from sipsimple.msrpstream import MSRPChat

KEY_NEXT_SESSION = '\x0e' # Ctrl-N
KEY_AUDIO_CONTROL = '\x00' # Ctrl-SPACE
KEY_TOGGLE_HOLD = '\x08' # Ctrl-H

trafficlog.hook_std_output()

log.level.current = log.level.WARNING

class UserCommandError(Exception):
    pass

class NotificationHandler(util.NotificationHandler):

    def subscribe_to_all(self, sender=Any):
        return util.NotificationHandler.subscribe_to_all(self, sender=sender, observer=NotifyFromThreadObserver(self))

def format_display_user_host(display, user, host):
    if display:
        return '%s (%s@%s)' % (display, user, host)
    else:
        return '%s@%s' % (user, host)

def format_uri(sip_uri, cpim_uri=None):
    if cpim_uri is not None:
        if (sip_uri.host, sip_uri.user) == (cpim_uri.host, cpim_uri.user):
            return format_display_user_host(cpim_uri.display or sip_uri.display, sip_uri.user, sip_uri.host)
        else:
            # conference, pasting only header from cpim
            return format_display_user_host(cpim_uri.display, cpim_uri.user, cpim_uri.host)
    return format_display_user_host(sip_uri.display, sip_uri.user, sip_uri.host)

def format_datetime(dt):
    """Format time in the local timezone.
    dt is datetime with tzinfo = UTC (or None which will be treated like UTC).

    >>> from sipsimple.clients.iso8601 import parse_date
    >>> time.timezone == -6*60*60 # this test can only be executed in Novosibirsk
    True
    >>> format_datetime(parse_date('2009-02-03T14:30:04'))
    '20:30:04'
    """
    if dt.tzinfo is None or not dt.tzinfo.utcoffset(dt):
        dt -= datetime.timedelta(seconds=time.timezone)
        if dt.date()==datetime.date.today():
            return dt.strftime('%X')
        else:
            return dt.strftime('%X %x')
    else:
        return repr(dt)

def format_incoming_message(text, uri, cpim_from, dt):
    if dt is None:
        return '%s: %s' % (format_uri(uri, cpim_from), text)
    else:
        return '%s %s: %s' % (format_datetime(dt), format_uri(uri, cpim_from), text)

def format_outgoing_message(uri, message, dt):
    return '%s %s: %s' % (format_datetime(dt), format_uri(uri), message)


class MessageRenderer(NotificationHandler):

    def start(self):
        self.subscribe_to_all()

    def _NH_MSRPChatGotMessage(self, msrpchat, data):
        session = msrpchat._chatsession
        try:
            msg = format_incoming_message(data.content, session.inv.remote_uri,
                                          data.cpim_headers.get('From'), data.cpim_headers.get('DateTime'))
        except ValueError:
            chunk = data.message
            print 'Failed to parse incoming message, content_type=%r, data=%r' % (chunk.content_type, chunk.data)
            # XXX: issue REPORT here?
        else:
            print msg
            if session.history_file:
                session.history_file.write(msg + '\n')
                session.history_file.flush()

def get_history_file(invitation):
    return _get_history_file('%s@%s' % (invitation.local_uri.user, invitation.local_uri.host),
                             '%s@%s' % (invitation.remote_uri.user, invitation.remote_uri.host),
                             invitation.is_outgoing)

def _get_history_file(local_uri, remote_uri, is_outgoing):
    settings = SIPSimpleSettings()
    dir = os.path.join(settings.chat.history_directory.normalized, local_uri)
    if is_outgoing:
        direction = 'outgoing'
    else:
        direction = 'incoming'
    time = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    if not os.path.exists(dir):
        os.makedirs(dir)
    filename = os.path.join(dir, '%s-%s-%s.txt' % (time, remote_uri, direction))
    return file(filename, 'a')


class ChatSession(NotificationHandler):

    info = 'Session'

    def __init__(self, session, manager, remote_party):
        self.session = session
        self.session._chat = self
        self.manager = manager
        self.remote_party = remote_party
        self.history_file = None
        self.put_on_hold = False
        if self.inv is not None:
            self.history_file = get_history_file(self.inv)
            if self.remote_party is None:
                self.remote_party = format_uri(self.inv.remote_uri)
        self.subscribe_to_all(sender=self.session)

    def __getattr__(self, item):
        return getattr(self.session, item)

    def _NH_SIPSessionDidStart(self, session, _data):
        if self.history_file is None:
            self.history_file = get_history_file(session.inv)

    def _NH_SIPSessionGotStreamUpdate(self, session, data):
        self.update_info(data.streams)

    def end(self):
        self.session.end()
        if self.history_file:
            self.history_file.close()
            self.history_file = None

    def send_message(self, msg):
        dt = datetime.datetime.utcnow()
        chunk = self.session.send_message(msg, dt=dt)
        printed_msg = format_outgoing_message(self.inv.local_uri, msg, dt=dt)
        print printed_msg
        if self.history_file:
            self.history_file.write(printed_msg + '\n')
            self.history_file.flush()
        return chunk

    def format_prompt(self):
        result = '%s to %s' % (self.info, self.remote_party)
        state = getattr(self.inv, 'state', None)
        if state != 'CONFIRMED':
            result += ' [%s]' % state
        return result + ': '

    def update_info(self, streams):
        self.info = '/'.join([type(stream).__name__ for stream in streams])
        if not self.info:
            self.info = 'Session with no streams'
        self.manager.update_prompt()

    def hold(self):
        self.session.hold()
        self.put_on_hold = True

    def unhold(self):
        self.session.unhold()
        self.put_on_hold = False

    def toggle_hold(self):
        if self.put_on_hold:
            self.unhold()
        else:
            self.hold()


class ChatManager(NotificationHandler):

    def __init__(self, engine, account, console, logger):
        self.engine = engine
        self.account = account
        self.console = console
        self.logger = logger
        self.sessions = []
        self.current_session = None
        self.procs = proc.RunningProcSet()
        self.subscribe_to_all()

    def _NH_SIPSessionDidEnd(self, session, data):
        try:
            self.remove_session(session._chat)
        except ValueError:
            pass

    _NH_SIPSessionDidFail = _NH_SIPSessionDidEnd

    def _NH_SIPSessionNewIncoming(self, session, data):
        self.procs.spawn(self._handle_incoming, session, data)

    def _NH_SIPSessionChangedState(self, session, data):
        self.update_prompt()

    # this notification is handled here and not on the session because we have access to the console here
    def _NH_SIPSessionGotStreamProposal(self, session, data):
        if data.proposer == 'remote':
            self.procs.spawn(self._handle_proposal, session, data)

    def _handle_proposal(self, session, data):
        txt = '/'.join(x.capitalize() for x in data.streams)
        question = '%s wants to add %s, do you accept? (y/n) ' % (format_uri(self.inv.caller_uri), txt)
        with linked_notification(name='SIPSessionChangedState', sender=session) as q:
            p1 = proc.spawn(proc.wrap_errors(proc.ProcExit, self.console.ask_question), question, list('yYnN') + [CTRL_D])
            # spawn a greenlet that will wait for a change in session state and kill p1 if there is
            p2 = proc.spawn(lambda : q.wait() and p1.kill())
            try:
                result = p1.wait() in ['y', 'Y']
            finally:
                p2.kill()
        if result:
            session.accept_proposal(chat='chat' in data.streams, audio='audio' in data.streams)
        else:
            session.reject_proposal()

    def _handle_incoming(self, session, data):
        session._chat = ChatSession(session, self)
        session._chat.info = '/'.join(x.capitalize() for x in data.streams)
        has_chat = 'chat' in data.streams
        has_audio = 'audio' in data.streams
        replies = list('yYnN') + [CTRL_D]
        replies_txt = 'y/n'
        if has_chat and has_audio:
            replies += list('aAcC')
            replies_txt += '/a/c'
        question = 'Incoming %s request from %s, do you accept? (%s) ' % (session._chat.info, self.inv.caller_uri, replies_txt)
        with linked_notification(name='SIPSessionChangedState', sender=session) as q:
            p1 = proc.spawn(proc.wrap_errors(proc.ProcExit, self.console.ask_question), question, replies)
            # spawn a greenlet that will wait for a change in session state and kill p1 if there is
            p2 = proc.spawn(lambda : q.wait() and p1.kill())
            try:
                result = p1.wait()
            finally:
                p2.kill()
        if result in list('aA'):
            has_audio = True
            has_chat = False
        elif result in list('cC'):
            has_audio = False
            has_chat = True
        if result in list('yYaAcC'):
            session.accept(chat=has_chat, audio=has_audio)
            self.add_session(session._chat)
        else:
            session.end()

    def close(self):
        for session in self.sessions[:]:
            self.procs.spawn(session.end)
        self.sessions = []
        self.update_prompt()
        self.procs.waitall()

    def close_current_session(self):
        if self.current_session is not None:
            self.procs.spawn(self.current_session.end)
            self.remove_session(self.current_session)

    def update_prompt(self):
        if self.current_session:
            prefix = ''
            if len(self.sessions)>1:
                prefix = '%s/%s ' % (1+self.sessions.index(self.current_session), len(self.sessions))
            ps = prefix + self.current_session.format_prompt()
        else:
            if hasattr(self.account, 'credentials'):
                credentials = self.account.credentials
                username, domain, port = credentials.uri.user, credentials.uri.host, credentials.uri.port
                if port in [None, 0, 5060]:
                    ps = '%s@%s' % (username, domain)
                else:
                    ps = '%s@%s:%s' % (username, domain, port)
            else:
                ps = str(getattr(self.account, 'contact', None))
            ps += '> '
        self.console.set_prompt(ps)

    def add_session(self, session, activate=True):
        assert session is not None
        self.sessions.append(session)
        if activate:
            self.current_session = session
            self.update_prompt()

    def remove_session(self, session):
        assert isinstance(session, ChatSession), repr(session)
        if session is None:
            return
        try:
            index = self.sessions.index(session)
        except ValueError:
            pass
        else:
            del self.sessions[index]
            if self.sessions:
                if self.current_session is session:
                    self.current_session = self.sessions[index % len(self.sessions)]
            else:
                self.current_session = None
        self.update_prompt()

    def get_shortcuts(self):
        return {KEY_NEXT_SESSION: self.cmd_switch,
                KEY_AUDIO_CONTROL: self.dtmf_numpad,
                KEY_TOGGLE_HOLD: self.toggle_hold}

    def get_cmd(self, cmd):
        return getattr(self, 'cmd_%s' % cmd, None)

    def cmd_help(self):
        """:help \t Print this help message"""
        lines = []
        for k in dir(self):
            if k.startswith('cmd_'):
                doc = getattr(self, k).__doc__
                if doc:
                    usage, desc = doc.split(' \t ')
                    lines.append((usage, desc))
        usage_width = max(len(x[0]) for x in lines) + 3
        for usage, desc in lines:
            print usage + ' ' * (usage_width-len(usage)) + desc

    def cmd_switch(self):
        """:switch  (or CTRL-N) \t Switch between active sessions"""
        if len(self.sessions)<2:
            print "There's no other session to switch to."
        else:
            index = 1+self.sessions.index(self.current_session)
            self.current_session = self.sessions[index % len(self.sessions)]
            self.update_prompt()

    streams = {'chat': MSRPChat}
    default_stream = MSRPChat

    def get_stream(self, s):
        s = s.replace('+', '').lower()
        s = complete_word(s.lower(), self.streams.keys())
        return self.streams[s]

    def cmd_call(self, *args):
        """:call user@domain [+]chat \t Initiate an outgoing session. By default, use audio. The second argument specifies whether to propose IM-only session ("chat") or audio+chat ("+chat")"""
        if not args:
            raise UserCommandError('Please provide uri\n%s' % self.cmd_call.__doc__)
        target_uri, streams = args[0], args[1:]
        if not isinstance(target_uri, SIPURI):
            try:
                target_uri = self.engine.parse_sip_uri(format_cmdline_uri(target_uri, self.account.id.domain))
            except ValueError, ex:
                raise UserCommandError(str(ex))
        if not streams:
            streams = [self.default_stream]
        elif streams[0][:1]=='+':
            streams = [self.default_stream] + [self.get_stream(x) for x in streams]
        else:
            streams = [self.get_stream(x) for x in streams]
        streams = [Stream(self.account) for Stream in streams]
        self.procs.spawn(self._call, target_uri, streams)

    def _call(self, target_uri, streams):
        chat = None
        try:
            session = GreenSession(self.account)
            chat = ChatSession(session, self, remote_party=format_uri(target_uri))
            chat.update_info(streams)
            self.add_session(chat)
            routes = get_routes(target_uri, self.engine, self.account)
            if not routes:
                print 'ERROR: No route found to SIP proxy for "%s"' % target_uri
                return
            for stream in streams:
                stream._chatsession = chat
            chat.connect(target_uri, routes, streams=streams)
            chat = None
        except InvitationError, ex:
            pass # already logged by InfoPrinter
        finally:
            if chat is not None:
                self.remove_session(chat)

    @staticmethod
    def make_SDPMedia(uri_path):
        return make_SDPMedia(uri_path, ['message/cpim'], ['text/plain'])

    def get_current_session(self, error_prefix=None):
        session = self.current_session
        if not session:
            if not error_prefix:
                msg = 'No active session'
            else:
                msg = error_prefix + ': no active session'
            raise UserCommandError(msg)
        return session

    def send_message(self, message):
        session = self.get_current_session('Cannot send message %r' % message)
        try:
            if session.send_message(message):
                #print 'sent %s %s' % (session, message)
                return True # indicate that the message was send and echoed
        except ConnectionClosed, ex:
            proc.spawn(self.remove_session, session)
            raise UserCommandError(str(ex))

    def cmd_hold(self):
        """:hold  (or CTRL-H) \t Put the current session on hold"""
        self.get_current_session().hold()

    def cmd_unhold(self):
        """:unhold  (or CTRL-H) \t Un-hold the current session"""
        self.get_current_session().unhold()

    def toggle_hold(self):
        self.get_current_session().toggle_hold()

    def cmd_add(self, *args):
        """:add audio|chat \t Add a new stream to the current session"""
        session = self.get_current_session()
        if len(args) != 1:
            raise UserCommandError('Invalid number of arguments\n:%s' % self.cmd_add.__doc__)
        session.add_stream(self.get_stream(args[0]))

    def cmd_remove(self, *args):
        """:remove audio|chat \t Remove the stream from the current session"""
        session = self.get_current_session()
        if len(args) != 1:
            raise UserCommandError('Invalid number of arguments\n:%s' % self.cmd_remove.__doc__)
        session.remove_stream(self.get_stream(args[0]))

    def cmd_dtmf(self, *args):
        """:dtmf DIGITS \t Send DTMF digits. Also try CTRL-SPACE for virtual numpad"""
        session = self.get_current_session()
        data = ''.join(args).upper()
        for x in data:
            if x not in "0123456789*#ABCD":
                raise UserCommandError('Invalid DTMF digit: %r' % x)
        for x in data:
            session.send_dtmf(x)

    char_to_digit = {}
    def _extend(dict, keys, value):
        for key in keys:
            dict[key] = value
    _extend(char_to_digit, 'ABC',  '2')
    _extend(char_to_digit, 'DEF',  '3')
    _extend(char_to_digit, 'GHI',  '4')
    _extend(char_to_digit, 'JKL',  '5')
    _extend(char_to_digit, 'MNO',  '6')
    _extend(char_to_digit, 'PQRS', '7')
    _extend(char_to_digit, 'TUV',  '8')
    _extend(char_to_digit, 'WXYZ', '9')

    def dtmf_numpad(self, *args):
        session = self.get_current_session()
        if not session.has_audio:
            raise UserCommandError('Session does not have audio stream to send DTMF over')
        print """\
+------+-----+------+
|  1   |  2  |  3   |
|      | ABC | DEF  |
+------+-----+------+
|  4   |  5  |  6   |
| GHI  | JKL | MNO  |
+------+-----+------+
|  7   |  8  |  9   |
| PQRS | TUV | WXYZ |
+------+-----+------+
|  *   |  0  |  #   |
+-------------------+
"""
        console = self.console
        digits = '1234567890*#' + ''.join(self.char_to_digit.keys()) +''.join(self.char_to_digit.keys()).lower()
        old_send_keys = console.terminalProtocol.send_keys[:]
        try:
            console.terminalProtocol.send_keys.extend(digits)
            prompt = '> '
            with console.temporary_prompt(prompt):
                while True:
                    type, (keyID, modifier) = console.recv_char(echo=False)
                    if keyID in [KEY_AUDIO_CONTROL, '\x1b', CTRL_D, '\n']:
                        return
                    digit = str(keyID).upper()
                    digit = self.char_to_digit.get(digit, digit)
                    if digit not in '0123456789*#':
                        print 'Invalid digit: %r' % digit
                    else:
                        prompt += str(digit)
                        console.set_prompt(prompt, 1)
                        session.send_dtmf(digit)
        finally:
            console.terminalProtocol.send_keys = old_send_keys

    def cmd_trace(self, *args):
        """:trace sip|pjsip|notifications \t Toggle the debug messages of given category"""
        if not args:
            raise UserCommandError('Please provide an argument\n%s' % self.cmd_trace.__doc__)
        args = [complete_word(x, ['sip', 'pjsip', 'msrp', 'notifications']) for x in args]
        for arg in args:
            if arg == 'sip':
                self.logger.sip_to_stdout = not self.logger.sip_to_stdout
                settings = SIPSimpleSettings()
                self.engine._obj.trace_sip = self.logger.sip_to_stdout or settings.logging.trace_sip
                print "SIP tracing to console is now %s" % ("activated" if self.logger.sip_to_stdout else "deactivated")
            elif arg == 'pjsip':
                self.logger.pjsip_to_stdout = not self.logger.pjsip_to_stdout
                settings = SIPSimpleSettings()
                self.engine._obj.log_level = settings.logging.pjsip_level if (self.logger.pjsip_to_stdout or settings.logging.trace_pjsip) else 0
                print "PJSIP tracing to console is now %s" % ("activated, log level=%s" % self.engine.log_level if self.logger.pjsip_to_stdout else "deactivated")
            elif arg == 'notifications':
                logstate.EngineTracer().toggle()
                print "Notifications tracing to console is now %s" % ("activated" if logstate.EngineTracer().started() else "deactivated")

    def cmd_echo(self, *args):
        """:echo +|-|MILISECONDS \t Adjust echo cancellation"""
        if not args:
            print 'Current echo cancellation: %s' % self.engine.ec_tail_length
            return
        if len(args)>1:
            raise UserCommandError("This command has one argument only\n%s" % self.cmd_echo.__doc__)
        param = args[0]
        try:
            number = float(param)
        except ValueError:
            if param == '+':
                number = 10
            elif param == '-':
                number = -10
            else:
                raise UserCommandError("Cannot understand %r\n%s" % (param, self.cmd_echo.__doc__))
        if param[0] in '+-':
            number = self.engine.ec_tail_length + number
        number = min(500, max(0, number))
        self.engine.set_sound_devices(tail_length=number)
        print "Set echo cancellation tail length to %s ms" % self.engine.ec_tail_length

    def cmd_record(self, *args):
        """:record \t Toggle audio recording"""
        session = self.get_current_session()
        if session.audio_recording_file_name is None:
            session.start_recording_audio()
        else:
            session.stop_recording_audio()


def complete_word(input, wordlist):
    """
    >>> complete_word('audio', ['chat', 'audio'])
    'audio'
    >>> complete_word('audiox', ['chat', 'audio'])
    Traceback (most recent call last):
     ...
    UserCommandError: Please provide chat|audio. Cannot understand 'audiox'
    >>> complete_word('c', ['chat', 'audio'])
    'chat'
    >>> complete_word('au', ['chat', 'audio', 'audi'])
    Traceback (most recent call last):
     ...
    UserCommandError: Please provide chat|audio|audi. Cannot understand 'au'
    """
    if input in wordlist:
        return input
    else:
        results = []
        for word in wordlist:
            if word.startswith(input):
                results.append(word)
        if len(results)==1:
            return results[0]
        else:
            raise UserCommandError('Please provide %s. Cannot understand %r' % ('|'.join(wordlist), input))


class InfoPrinter(NotificationHandler):

    def _NH_SIPEngineDetectedNATType(self, sender, data):
        if data.succeeded:
            print "Detected NAT type: %s" % data.nat_type

    def _NH_SIPSessionDidStart(self, session, _data):
        try:
            print 'Session established, using "%s" codec at %dHz' % (session.audio_codec, session.audio_sample_rate)
            print "Audio RTP endpoints %s:%d <-> %s:%d" % (session.audio_local_rtp_address, session.audio_local_rtp_port,
                                                           session.audio_remote_rtp_address_sdp, session.audio_remote_rtp_port_sdp)
            if session.audio_srtp_active:
                print "RTP audio stream is encrypted"
        except AttributeError:
            pass
        if session.remote_user_agent is not None:
            print 'Remote SIP User Agent is "%s"' % session.remote_user_agent

    def _NH_MSRPChatDidStart(self, chat, data):
        transport = chat.msrp.msrp
        print 'MSRP endpoints %s:%s <-> %s:%s' % (transport.getHost().host, transport.getHost().port,
                                                  transport.getPeer().host, transport.getPeer().port)

    def _NH_SIPSessionDidFail(self, session, data):
        if data.code:
            print "Session failed: %d %s" % (data.code, data.reason)
        else:
            print "Session failed: %s" % data.reason

    def _NH_SIPSessionDidEnd(self, session, data):
        after = ''
        if session.stop_time is not None:
            duration = session.stop_time - session.start_time
            after = " after %s%s%d seconds" % ("%d days, " % duration.days if duration.days else "", "%d minutes, " % (duration.seconds / 60) if duration.seconds > 60 else "", duration.seconds % 60)
        if data.originator == 'local':
            print "Session ended by local party%s." % after
        else:
            print "Session ended by remote party%s." % after

    def _NH_SIPSessionRejectedStreamProposal(self, session, data):
        print data.reason

    def _NH_SIPSessionGotHoldRequest(self, session, data):
        if data.originator == 'local':
            print "Call is put on hold"
        else:
            print "Remote party has put the audio session on hold"

    def _NH_SIPSessionGotUnholdRequest(self, session, data):
        if data.originator == "local":
            print "Call is taken out of hold"
        else:
            print "Remote party has taken the audio session out of hold"

    def _NH_SIPAccountRegistrationDidSucceed(self, account, data):
        route = data.registration.route
        print 'Registered contact "%s" for sip:%s at %s:%d;transport=%s (expires in %d seconds)' % \
            (data.contact_uri, account.id, route.address, route.port,
             route.transport, data.registration.expires)

    def _NH_SIPAccountRegistrationDidFail(self, account, data):
        if data.registration is not None:
            route = data.registration.route
            if data.next_route:
                next_route = data.next_route
                next_route = 'Trying next route %s:%d;transport=%s.' % (next_route.address, next_route.port, next_route.transport)
            else:
                next_route = 'No more routes to try; retrying in %.2f seconds.' % (data.delay)
            if 'code' in data.__dict__:
                status = '%d %s' % (data.code, data.reason)
            else:
                status = data.reason
            print 'Failed to register contact for sip:%s at %s:%d;transport=%s: %s. %s' % (account.id, route.address, route.port, route.transport, status, next_route)
        else:
            print 'Failed to register contact for sip:%s: %s' % (account.id, data.reason)

    def _NH_SIPAccountRegistrationDidEnd(self, account, data):
        if 'code' in data.__dict__:
            print 'Registration ended: %d %s.' % (data.code, data.reason)
        else:
            print 'Registration ended.'

    def _NH_SIPSessionDidStartRecordingAudio(self, session, data):
        print 'Recording audio to "%s"' % data.file_name

    def _NH_SIPSessionDidStopRecordingAudio(self, session, data):
        print 'Stopped recording audio to "%s"' % data.file_name

def start(options, console):
    account = options.account
    settings = SIPSimpleSettings()
    engine = GreenEngine()
    engine.start_cfg(enable_sound=not options.disable_sound,
        log_level=settings.logging.pjsip_level if (settings.logging.trace_pjsip or options.trace_pjsip) else 0,
        trace_sip=settings.logging.trace_sip or options.trace_sip)
    try:
        if engine.recording_devices:
            print "Available audio input devices: %s" % ", ".join(sorted(engine.recording_devices))
        if engine.recording_devices:
            print "Available audio output devices: %s" % ", ".join(sorted(engine.playback_devices))
        if not options.disable_sound:
            engine.set_sound_devices(playback_device=settings.audio.output_device, recording_device=settings.audio.input_device)
            print "Using audio input device: %s" % engine.current_recording_device
        print "Using audio output device: %s" % engine.current_playback_device
        engine.codecs = list(account.audio.codec_list)
        if hasattr(options.account, "stun_servers") and len(options.account.stun_servers) > 0:
            engine.detect_nat_type(*options.account.stun_servers[0])
        if options.trace_notifications:
            logstate.EngineTracer().start()
        if isinstance(account, BonjourAccount):
            if engine.local_udp_port:
                print 'Local contact: %s:%s;transport=udp' % (account.contact, engine.local_udp_port)
            if engine.local_tcp_port:
                print 'Local contact: %s:%s;transport=tcp' % (account.contact, engine.local_tcp_port)
            if engine.local_tls_port:
                print 'Local contact: %s:%s;transport=tls' % (account.contact, engine.local_tls_port)
        MessageRenderer().start()
        session_manager = SessionManager()
        manager = ChatManager(engine, account, console, options.logger)
        manager.update_prompt()
        try:
            print "Type :help to get information about commands and shortcuts"
            if not options.args:
                print 'Waiting for incoming SIP session requests...'
            else:
                try:
                    manager.cmd_call(*options.args)
                except (UserCommandError, SessionStateError), ex:
                    print str(ex)
            while True:
                try:
                    readloop(console, manager, manager.get_shortcuts())
                except EOF:
                    if manager.current_session:
                        manager.close_current_session()
                    else:
                        raise
        except BaseException, ex:
            # will print the exception myself, because finally section takes
            # time and maybe interrupted thus hiding the original exception
            if type(ex) is not EOF:
                import traceback
                traceback.print_exc()
        finally:
            console.copy_input_line()
            with calming_message(1, "Disconnecting the session(s)..."):
                manager.close()
    finally:
        with calming_message(1, "Disconnecting the session(s)..."):
            proc.waitall([proc.spawn(session.end) for session in SessionManager().sessions])
        RegistrationManager().unregister()
        with calming_message(2, "Stopping the engine..."):
            engine.stop()
        api.sleep(0.1)

@contextmanager
def calming_message(seconds, message):
    """Print `message' after `seconds'."""
    t = api.get_hub().schedule_call(seconds, sys.stdout.write, message + '\n')
    try:
        yield t
    finally:
        t.cancel()

def readloop(console, manager, shortcuts):
    console.terminalProtocol.send_keys.extend(shortcuts.keys())
    for type, value in console:
        if type == 'key':
            key = value[0]
            if key in shortcuts:
                try:
                    shortcuts[key]()
                except (UserCommandError, SessionStateError), ex:
                    print ex
        elif type == 'line':
            echoed = []
            def echo():
                """Echo user's input line, once. Note, that manager.send_message() may do echo
                itself (it indicates if it did it in the return value).
                """
                if not echoed:
                    console.copy_input_line(value)
                    echoed.append(1)
            try:
                command = value[1:] and value[1:].split() and manager.get_cmd(value[1:].split()[0])
                if command:
                    echo()
                    args = value[1:].split()
                    command(*args[1:])
                else:
                    if value:
                        if manager.send_message(value):
                            echoed.append(1)
            except (UserCommandError, SessionStateError), ex:
                echo()
                print ex
            # will get there without echoing if user pressed enter on an empty line; let's echo it
            echo()


description = "This script will either sit idle waiting for an incoming session, or start a new session with the specified target SIP address. The program will close the session and quit when CTRL-D is pressed. This scripts supports RTP audio and MSRP chat sessions."
usage = "%prog [options] [target-user@target-domain.com] [audio|chat]"

def get_account(key):
    account_manager = AccountManager()
    accounts = account_manager.accounts
    if not accounts:
        sys.exit('No accounts defined')
    if key is None:
        if account_manager.default_account is not None:
            return account_manager.default_account
        elif len(accounts)==1:
            return accounts.items()[0]
        else:
            sys.exit('Please specify account to use with "-a username@domain" option')
    try:
        return accounts[key]
    except KeyError:
        matched = []
        for x in accounts:
            if x.find(key) != -1:
                matched.append(x)
        if not matched:
            sys.exit('None of the accounts matches %r' % key)
        elif len(matched)>1:
            sys.exit('The following accounts match %r:\n%s\nPlease provide longer substring' % (key, '\n'.join(matched)))
        return accounts[matched[0]]

def get_routes(target_uri, engine, account):
    settings = SIPSimpleSettings()
    if not isinstance(target_uri, SIPURI):
        target_uri = engine.parse_sip_uri(format_cmdline_uri(target_uri, account.id.domain))
    if account.id == "bonjour@local":
        routes = lookup_routes_for_sip_uri(target_uri, settings.sip.transports)
    elif account.outbound_proxy is None:
        routes = lookup_routes_for_sip_uri(target_uri, settings.sip.transports)
    else:
        proxy_uri = SIPURI(host=account.outbound_proxy.host, port=account.outbound_proxy.port,
                           parameters={"transport": account.outbound_proxy.transport})
        routes = lookup_routes_for_sip_uri(proxy_uri, settings.sip.transports)
    return routes

class RegistrationManager(NotificationHandler):
    __metaclass__ = Singleton

    def __init__(self):
        self.accounts = set()

    def start(self):
        NotificationCenter().add_observer(NotifyFromThreadObserver(self), name='SIPAccountRegistrationDidSucceed')
        NotificationCenter().add_observer(NotifyFromThreadObserver(self), name='SIPAccountRegistrationDidEnd')
        NotificationCenter().add_observer(NotifyFromThreadObserver(self), name='SIPAccountRegistrationDidFail')

    def _NH_SIPAccountRegistrationDidSucceed(self, account, data):
        self.accounts.add(account)

    def _NH_SIPAccountRegistrationDidEnd(self, account, data):
        self.accounts.discard(account)

    def _NH_SIPAccountRegistrationDidFail(self, account, data):
        self.accounts.discard(account)

    def unregister(self):
        with linked_notifications(names=['SIPAccountRegistrationDidFail', 'SIPAccountRegistrationDidEnd']) as q:
            AccountManager().stop()
            with api.timeout(1, None):
                while self.accounts:
                    notification = q.wait()
                    self.accounts.discard(notification.sender)

def parse_options(usage, description):
    parser = OptionParser(usage=usage, description=description)
    parser.add_option("-a", "--account-name", type="string", metavar='ACCOUNT_NAME',
                      help='The name of the account to use.')
    parser.add_option("--no-register", dest='register', default=True, action='store_false',
                      help='Bypass registration.')
    parser.add_option("-c", "--config_file", type="string", dest="config_file",
                      help="The path to a configuration file to use. "
                           "This overrides the default location of the configuration file.", metavar="FILE")
    parser.add_option("-S", "--disable-sound", default=False,
                      action="store_true", help="Disables initializing the sound card.")
    parser.add_option("-s", "--trace-sip", action="store_true",
                      dest="trace_sip", default=False,
                      help="Dump the raw contents of incoming and outgoing SIP messages. ")
    parser.add_option("-j", "--trace-pjsip", action="store_true",
                      dest="trace_pjsip", default=False,
                      help="Print PJSIP logging output.")
    parser.add_option("--trace-notifications", action="store_true", help="Print core's events.")
    parser.add_option("-m", "--trace-msrp", action="store_true",
                      help="Log the raw contents of incoming and outgoing MSRP messages.")
    parser.add_option("--no-relay", action='store_true', help="Don't use the MSRP relay.")
    parser.add_option("--msrp-tcp", action='store_true', help="Use TCP for MSRP connections.")
    options, args = parser.parse_args()
    options.args = args
    return options

def update_settings(options):
    settings = SIPSimpleSettings()
    account = get_account(options.account_name)
    for other_account in AccountManager().iter_accounts():
        if other_account is not account:
            if hasattr(other_account, 'registration'):
                other_account.registration.enabled = False
    if not options.register:
        account.registration.enabled = False
    options.account = account
    print 'Using account %s' % account.id
    if options.trace_msrp is not None:
        settings.logging.trace_msrp = options.trace_msrp
    if account.id != "bonjour@local":
        if account.stun_servers:
            account.stun_servers = tuple((gethostbyname(stun_host), stun_port) for stun_host, stun_port in account.stun_servers)
        else:
            account.stun_servers = lookup_service_for_sip_uri(SIPURI(host=account.id.domain), "stun")
    if options.no_relay:
        account.msrp.use_relay_for_inbound = False
        account.msrp.use_relay_for_outbound = False
    if options.msrp_tcp:
        settings.msrp.transport = 'tcp'

def main():
    options = parse_options(usage, description)

    RegistrationManager().start()
    ConfigurationManager().start(ConfigFileBackend(options.config_file))
    AccountManager().start()
    settings = SIPSimpleSettings()

    update_settings(options)

    if settings.ringtone.inbound is None:
        settings.ringtone.inbound = get_path("ring_inbound.wav")
    if settings.ringtone.outbound is None:
        settings.ringtone.outbound = get_path("ring_outbound.wav")
    if settings.chat.message_received_sound is None:
        settings.chat.message_received_sound = get_path("message_received.wav")
    if settings.chat.message_sent_sound is None:
        settings.chat.message_sent_sound = get_path("message_sent.wav")

    # set up logger
    options.logger = Logger(options.trace_sip, options.trace_pjsip)
    options.logger.start()
    if settings.logging.trace_sip:
        print "Logging SIP trace to file '%s'" % options.logger._siptrace_filename
    if settings.logging.trace_pjsip:
        print "Logging PJSIP trace to file '%s'" % options.logger._pjsiptrace_filename
    if LoggerSingleton().msrptrace_filename:
        print "Logging MSRP trace to file '%s'" % LoggerSingleton().msrptrace_filename

    InfoPrinter().subscribe_to_all()

    try:
        with setup_console() as console:
            start(options, console)
    except EOF:
        pass
    except proc.LinkedExited, err:
        print 'Exiting because %s' % (err, )
    except (RuntimeError, SIPCoreError), e:
        sys.exit(str(e) or str(type(e)))

if __name__ == "__main__":
    main()

