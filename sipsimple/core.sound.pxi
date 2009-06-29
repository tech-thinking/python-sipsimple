# Copyright (C) 2008-2009 AG Projects. See LICENSE for details.
#

# classes

cdef class ConferenceBridge:
    # instance attributes
    cdef pjmedia_conf *_obj
    cdef pj_pool_t *_conf_pool
    cdef pjmedia_snd_port *_snd
    cdef pj_pool_t *_snd_pool
    cdef pjmedia_port *_null_port
    cdef pjmedia_master_port *_master_port
    cdef readonly str input_device
    cdef readonly str output_device
    cdef readonly int sample_rate
    cdef readonly int ec_tail_length
    cdef readonly int slot_count
    cdef int _disconnect_when_idle
    cdef int _volume
    cdef list _connected_slots
    cdef readonly int used_slot_count
    cdef int _is_muted

    # properties

    property volume:

        def __get__(self):
            return self._volume

        def __set__(self, int value):
            cdef int status
            cdef PJSIPUA ua = self._get_ua(1)
            if value < 0:
                raise ValueError("volume attribute cannot be negative")
            if ua is not None:
                status = pjmedia_conf_adjust_tx_level(self._obj, 0, int(value * 1.28 - 128))
                if status != 0:
                    raise PJSIPError("Could not set output volume of sound device", status)
            self._volume = value

    property connected_slots:

        def __get__(self):
            cdef PJSIPUA ua = self._get_ua(0)
            return sorted(self._connected_slots)

    property is_muted:

        def __get__(self):
            return bool(self._is_muted)

        def __set__(self, value):
            cdef int is_muted
            cdef PJSIPUA ua = self._get_ua(0)
            if self._obj == NULL:
                raise SIPCoreError("Conference bridge is already deallocated")
            is_muted = int(bool(value))
            if is_muted == self._is_muted:
                return
            if is_muted:
                status = pjmedia_conf_adjust_rx_level(self._obj, 0, 0)
            else:
                status = pjmedia_conf_adjust_rx_level(self._obj, 0, 128)
            if status != 0:
                raise PJSIPError("Could not set output volume of sound device", status)
            self._is_muted = is_muted

    # public methods

    def __cinit__(self, *args, **kwargs):
        self._disconnect_when_idle = 1
        self._volume = 100
        self._connected_slots = list()

    def __init__(self, str input_device, str output_device, int sample_rate,
                 int ec_tail_length=200, int slot_count=254):
        cdef str conf_pool_name
        cdef int status
        cdef PJSIPUA ua = _get_ua()
        if self._obj != NULL:
            raise SIPCoreError("ConferenceBridge.__init__() was already called")
        if sample_rate <= 0:
            raise ValueError("sample_rate argument should be a non-negative integer")
        if ec_tail_length < 0:
            raise ValueError("ec_tail_length argument cannot be negative")
        if sample_rate <= 0:
            raise ValueError("sample_rate argument should be a non-negative integer")
        if sample_rate % 50:
            raise ValueError("sample_rate argument should be dividable by 50")
        self.sample_rate = sample_rate
        self.slot_count = slot_count
        conf_pool_name = "ConferenceBridge_%d" % id(self)
        self._conf_pool = pjsip_endpt_create_pool(ua._pjsip_endpoint._obj, conf_pool_name, 4096, 4096)
        if self._conf_pool == NULL:
            raise SIPCoreError("Could not allocate memory pool")
        status = pjmedia_conf_create(self._conf_pool, slot_count+1, sample_rate, 1,
                                     sample_rate / 50, 16, PJMEDIA_CONF_NO_DEVICE, &self._obj)
        if status != 0:
            raise PJSIPError("Could not create conference bridge", status)
        self._start_sound_device(ua, input_device, output_device, ec_tail_length, 0)
        if self._disconnect_when_idle:
            self._stop_sound_device(ua)

    def __dealloc__(self):
        cdef PJSIPUA ua = self._get_ua(0)
        self._stop_sound_device(ua)
        if self._master_port != NULL:
            pjmedia_master_port_destroy(self._master_port, 0)
            self._master_port = NULL
        if self._null_port != NULL:
            pjmedia_port_destroy(self._null_port)
            self._null_port = NULL
        if self._obj != NULL:
            pjmedia_conf_destroy(self._obj)
            self._obj = NULL
        if self._conf_pool != NULL:
            pjsip_endpt_release_pool(ua._pjsip_endpoint._obj, self._conf_pool)
            self._conf_pool = NULL

    def set_sound_devices(self, str input_device, str output_device, int ec_tail_length):
        cdef PJSIPUA ua = self._get_ua(1)
        if ec_tail_length < 0:
            raise ValueError("ec_tail_length argument cannot be negative")
        if (input_device == self.input_device and output_device == self.output_device and
            ec_tail_length == self.ec_tail_length):
            return
        self._stop_sound_device(ua)
        self._start_sound_device(ua, input_device, output_device, ec_tail_length, 0)
        if self._disconnect_when_idle and self.used_slot_count == 0:
            self._stop_sound_device(ua)

    def connect_slots(self, int src_slot, int dst_slot):
        cdef tuple connection
        cdef int status
        cdef PJSIPUA ua = self._get_ua(1)
        if src_slot < 0:
            raise ValueError("src_slot argument cannot be negative")
        if dst_slot < 0:
            raise ValueError("d_slot argument cannot be negative")
        connection = (src_slot, dst_slot)
        if connection in self._connected_slots:
            return
        status = pjmedia_conf_connect_port(self._obj, src_slot, dst_slot, 0)
        if status != 0:
            raise PJSIPError("Could not connect slots on conference bridge", status)
        self._connected_slots.append(connection)

    def disconnect_slots(self, int src_slot, int dst_slot):
        cdef tuple connection
        cdef int status
        cdef PJSIPUA ua = self._get_ua(1)
        if src_slot < 0:
            raise ValueError("src_slot argument cannot be negative")
        if dst_slot < 0:
            raise ValueError("d_slot argument cannot be negative")
        connection = (src_slot, dst_slot)
        if connection not in self._connected_slots:
            return
        status = pjmedia_conf_disconnect_port(self._obj, src_slot, dst_slot)
        if status != 0:
            raise PJSIPError("Could not disconnect slots on conference bridge", status)
        self._connected_slots.remove(connection)

    # private methods

    cdef PJSIPUA _get_ua(self, int raise_exception):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
        except SIPCoreError:
            self._connected_slots = list()
            self.used_slot_count = 0
            self._snd = NULL
            self._snd_pool = NULL
            self._master_port = NULL
            self._null_port = NULL
            self._obj = NULL
            self._conf_pool = NULL
            if raise_exception:
                raise
            else:
                return None
        else:
            return ua

    cdef int _start_sound_device(self, PJSIPUA ua, str input_device, str output_device,
                                 int ec_tail_length, int revert_to_default) except -1:
        cdef int input_device_i = -2
        cdef int output_device_i = -2
        cdef int i
        cdef pjmedia_snd_stream_info snd_info
        cdef pjmedia_snd_dev_info_ptr_const dev_info
        cdef str sound_pool_name
        cdef int status
        if input_device == "default":
            input_device_i = -1
        if output_device == "default":
            output_device_i = -1
        if ((input_device_i == -2 and input_device is not None) or
            (output_device_i == -2 and output_device is not None)):
            for i from 0 <= i < pjmedia_snd_get_dev_count():
                dev_info = pjmedia_snd_get_dev_info(i)
                if (input_device is not None and input_device_i == -2 and
                    dev_info.input_count > 0 and dev_info.name == input_device):
                    input_device_i = i
                if (output_device is not None and output_device_i == -2 and
                    dev_info.output_count > 0 and dev_info.name == output_device):
                    output_device_i = i
            if input_device_i == -2 and input_device is not None:
                if revert_to_default:
                    input_device_i = -1
                else:
                    raise SIPCoreError('Audio input device "%s" not found' % input_device)
            if output_device_i == -2 and output_device is not None:
                if revert_to_default:
                    output_device_i = -1
                else:
                    raise SIPCoreError('Audio output device "%s" not found' % output_device)
        if input_device is None and output_device is None:
            status = pjmedia_null_port_create(self._conf_pool, self.sample_rate, 1,
                                              self.sample_rate / 50, 16, &self._null_port)
            if status != 0:
                raise PJSIPError("Could not create dummy audio port", status)
            status = pjmedia_master_port_create(self._conf_pool, self._null_port,
                                                pjmedia_conf_get_master_port(self._obj), 0, &self._master_port)
            if status != 0:
                raise PJSIPError("Could not create master port for dummy sound device", status)
            status = pjmedia_master_port_start(self._master_port)
            if status != 0:
                raise PJSIPError("Could not start master port for dummy sound device", status)
        else:
            snd_pool_name = "ConferenceBridge_snd_%d" % id(self)
            self._snd_pool = pjsip_endpt_create_pool(ua._pjsip_endpoint._obj, snd_pool_name, 4096, 4096)
            if self._snd_pool == NULL:
                raise SIPCoreError("Could not allocate memory pool")
            if input_device is None:
                status = pjmedia_snd_port_create_player(self._snd_pool, output_device_i, self.sample_rate,
                                                        1, self.sample_rate / 50, 16, 0, &self._snd)
            elif output_device is None:
                status = pjmedia_snd_port_create_rec(self._snd_pool, input_device_i, self.sample_rate,
                                                     1, self.sample_rate / 50, 16, 0, &self._snd)
            else:
                status = pjmedia_snd_port_create(self._snd_pool, input_device_i, output_device_i,
                                                 self.sample_rate, 1, self.sample_rate / 50, 16, 0, &self._snd)
            if status == PJMEDIA_ENOSNDPLAY:
                pjsip_endpt_release_pool(ua._pjsip_endpoint._obj, self._snd_pool)
                self._snd_pool = NULL
                self.start_sound_device(ua, None, output_device)
                return 0
            elif status == PJMEDIA_ENOSNDREC:
                pjsip_endpt_release_pool(ua._pjsip_endpoint._obj, self._snd_pool)
                self._snd_pool = NULL
                self.start_sound_device(ua, input_device, None)
                return 0
            elif status != 0:
                raise PJSIPError("Could not create sound device", status)
            if input_device is not None and output_device is not None:
                status = pjmedia_snd_port_set_ec(self._snd, self._snd_pool, ec_tail_length, 0)
                if status != 0:
                    self._stop_sound_device(ua)
                    raise PJSIPError("Could not set echo cancellation", status)
            status = pjmedia_snd_port_connect(self._snd, pjmedia_conf_get_master_port(self._obj))
            if status != 0:
                self._stop_sound_device(ua)
                raise PJSIPError("Could not connect sound device", status)
            if input_device_i == -1 or output_device_i == -1:
                status = pjmedia_snd_stream_get_info(pjmedia_snd_port_get_snd_stream(self._snd), &snd_info)
                if status != 0:
                    self._stop_sound_device(ua)
                    raise PJSIPError("Could not get sounds device info", status)
                if input_device_i == -1:
                    dev_info = pjmedia_snd_get_dev_info(snd_info.rec_id)
                    self.input_device = dev_info.name
                if output_device_i == -1:
                    dev_info = pjmedia_snd_get_dev_info(snd_info.play_id)
                    self.output_device = dev_info.name
            if input_device_i != -1:
                self.input_device = input_device
            if output_device_i != -1:
                self.output_device = output_device
            self.ec_tail_length = ec_tail_length
        return 0

    cdef int _stop_sound_device(self, PJSIPUA ua) except -1:
        if self._snd != NULL:
            pjmedia_snd_port_destroy(self._snd)
            self._snd = NULL
        if self._snd_pool != NULL:
            pjsip_endpt_release_pool(ua._pjsip_endpoint._obj, self._snd_pool)
            self._snd_pool = NULL
        return 0

    cdef int _add_port(self, PJSIPUA ua, pj_pool_t *pool, pjmedia_port *port) except -1:
        cdef unsigned int slot
        cdef int input_device_i
        cdef int output_device_i
        cdef int status
        status = pjmedia_conf_add_port(self._obj, pool, port, NULL, &slot)
        if status != 0:
            raise PJSIPError("Could not add audio object to conference bridge", status)
        self.used_slot_count += 1
        if (self.used_slot_count == 1 and self._disconnect_when_idle and
            not (self.input_device is None and self.output_device is None) and
            self._snd == NULL):
            self._start_sound_device(ua, self.input_device, self.output_device, self.ec_tail_length, 1)
        return slot

    cdef int _remove_port(self, PJSIPUA ua, unsigned int slot) except -1:
        cdef int status
        cdef tuple connection
        status = pjmedia_conf_remove_port(self._obj, slot)
        if status != 0:
            raise PJSIPError("Could not remove audio object from conference bridge", status)
        self._connected_slots = [connection for connection in self._connected_slots if slot not in connection]
        self.used_slot_count -= 1
        if (self.used_slot_count == 0 and self._disconnect_when_idle and
            not (self.input_device is None and self.output_device is None)):
            #self._stop_sound_device(ua)
            _add_post_handler(_ConferenceBridge_stop_sound_post, self)
        return 0


cdef class ToneGenerator:
    # instance attributes
    cdef pjmedia_port *_obj
    cdef pj_pool_t *_pool
    cdef readonly ConferenceBridge conference_bridge
    cdef int _slot
    cdef int _volume
    cdef pj_timer_entry _timer
    cdef int _timer_active

    # properties

    property volume:

        def __get__(self):
            return self._volume

        def __set__(self, value):
            cdef int status
            cdef PJSIPUA ua = self._get_ua(0)
            if value < 0:
                raise ValueError("volume attribute cannot be negative")
            if ua is not None and self._slot != -1:
                status = pjmedia_conf_adjust_rx_level(self.conference_bridge._obj, self._slot, int(value * 1.28 - 128))
                if status != 0:
                    raise PJSIPError("Could not set volume of tone generator", status)
            self._volume = value

    property slot:

        def __get__(self):
            if self._slot == -1:
                return None
            else:
                return self._slot

    property is_active:

        def __get__(self):
            return bool(self._slot != -1)

    property is_busy:

        def __get__(self):
            if self._obj == NULL:
                return False
            return bool(pjmedia_tonegen_is_busy(self._obj))

    # public methods

    def __cinit__(self, *args, **kwargs):
        cdef str pool_name
        cdef PJSIPUA ua = _get_ua()
        self._volume = 100
        self._slot = -1
        pool_name = "ToneGenerator_%d" % id(self)
        pj_timer_entry_init(&self._timer, 0, <void *> self, _ToneGenerator_cb_check_done)
        self._pool = pjsip_endpt_create_pool(ua._pjsip_endpoint._obj, pool_name, 4096, 4096)
        if self._pool == NULL:
            raise SIPCoreError("Could not allocate memory pool")

    def __init__(self, ConferenceBridge conference_bridge):
        cdef int status
        cdef PJSIPUA ua = _get_ua()
        if self._obj != NULL:
            raise SIPCoreError("ToneGenerator.__init__() was already called")
        if conference_bridge is None:
            raise ValueError("conference_bridge argument may not be None")
        self.conference_bridge = conference_bridge
        status = pjmedia_tonegen_create(self._pool, conference_bridge.sample_rate, 1,
                                        conference_bridge.sample_rate / 50, 16, 0, &self._obj)
        if status != 0:
            raise PJSIPError("Could not create tone generator", status)

    def start(self):
        cdef PJSIPUA ua = self._get_ua(1)
        self._slot = self.conference_bridge._add_port(ua, self._pool, self._obj)
        if self._volume != 100:
            self.volume = self._volume

    def __dealloc__(self):
        cdef PJSIPUA ua = self._get_ua(0)
        if self._timer_active:
            pjsip_endpt_cancel_timer(ua._pjsip_endpoint._obj, &self._timer)
            self._timer_active = 0
        if self._obj != NULL:
            self.conference_bridge._remove_port(ua, self._slot)
            pjmedia_tonegen_stop(self._obj)
            self._obj = NULL
        if self._pool != NULL:
            pjsip_endpt_release_pool(ua._pjsip_endpoint._obj, self._pool)
            self._pool = NULL

    def play_tones(self, object tones):
        cdef int freq1, freq2, duration
        cdef pjmedia_tone_desc tones_arr[PJMEDIA_TONEGEN_MAX_DIGITS]
        cdef unsigned int count = 0
        cdef int status
        cdef PJSIPUA ua = self._get_ua(1)
        if self._slot == -1:
            raise SIPCoreError("ToneGenerator has not yet been started")
        for freq1, freq2, duration in tones:
            if freq1 == 0 and count > 0:
                tones_arr[count-1].off_msec += duration
            else:
                if count >= PJMEDIA_TONEGEN_MAX_DIGITS:
                    raise SIPCoreError("Too many tones")
                tones_arr[count].freq1 = freq1
                tones_arr[count].freq2 = freq2
                tones_arr[count].on_msec = duration
                tones_arr[count].off_msec = 0
                tones_arr[count].volume = 0
                tones_arr[count].flags = 0
                count += 1
        if count > 0:
            status = pjmedia_tonegen_play(self._obj, count, tones_arr, 0)
            if status != 0:
                raise PJSIPError("Could not playback tones", status)
        if not self._timer_active:
            self._start_timer(ua)

    def play_dtmf(self, str digit):
        cdef pjmedia_tone_digit tone
        cdef int status
        cdef PJSIPUA ua = self._get_ua(1)
        if self._slot == -1:
            raise SIPCoreError("ToneGenerator has not yet been started")
        tone.digit = ord(digit)
        tone.on_msec = 200
        tone.off_msec = 50
        tone.volume = 0
        status = pjmedia_tonegen_play_digits(self._obj, 1, &tone, 0)
        if status != 0 and status != PJ_ETOOMANY:
            raise PJSIPError("Could not playback DTMF tone", status)
        if not self._timer_active:
            self._start_timer(ua)

    # private methods

    cdef PJSIPUA _get_ua(self, int raise_exception):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
        except SIPCoreError:
            self._obj = NULL
            self._pool = NULL
            self._slot = -1
            self._timer_active = 0
            if raise_exception:
                raise
            else:
                return None
        else:
            return ua

    cdef int _start_timer(self, PJSIPUA ua) except -1:
        cdef pj_time_val timeout
        cdef int status
        timeout.sec = 0
        timeout.msec = 250
        status = pjsip_endpt_schedule_timer(ua._pjsip_endpoint._obj, &self._timer, &timeout)
        if status != 0:
            raise PJSIPError("Could not set completion check timer", status)
        self._timer_active = 1
        return 0


cdef class PJMEDIAConferenceBridge:
    cdef pjmedia_conf *_obj
    cdef pjsip_endpoint *_pjsip_endpoint
    cdef PJMEDIAEndpoint _pjmedia_endpoint
    cdef pj_pool_t *_pool
    cdef pjmedia_port *_tonegen
    cdef unsigned int _tonegen_slot
    cdef pjmedia_snd_port *_snd
    cdef list _pb_in_slots, _conv_in_slots
    cdef list _all_out_slots, _conv_out_slots
    cdef pjmedia_port *_null_port
    cdef pjmedia_master_port *_master_port
    cdef int _do_playback_dtmf

    def __cinit__(self, PJSIPEndpoint pjsip_endpoint, PJMEDIAEndpoint pjmedia_endpoint, int playback_dtmf):
        cdef int status
        self._pjsip_endpoint = pjsip_endpoint._obj
        self._pjmedia_endpoint = pjmedia_endpoint
        self._do_playback_dtmf = playback_dtmf
        self._conv_in_slots = list([0])
        self._all_out_slots = list([0])
        self._pb_in_slots = list()
        self._conv_out_slots = list()
        status = pjmedia_conf_create(pjsip_endpoint._pool, 254, pjmedia_endpoint._sample_rate * 1000, 1,
                                     pjmedia_endpoint._sample_rate * 20, 16, PJMEDIA_CONF_NO_DEVICE, &self._obj)
        if status != 0:
            raise PJSIPError("Could not create conference bridge", status)
        status = pjmedia_null_port_create(pjsip_endpoint._pool, pjmedia_endpoint._sample_rate * 1000, 1,
                                          pjmedia_endpoint._sample_rate * 20, 16, &self._null_port)
        if status != 0:
            raise PJSIPError("Could not create dummy audio port", status)
        status = pjmedia_tonegen_create(pjsip_endpoint._pool, self._pjmedia_endpoint._sample_rate * 1000, 1,
                                        self._pjmedia_endpoint._sample_rate * 20, 16, 0, &self._tonegen)
        if status != 0:
            raise PJSIPError("Could not create DTMF tone generator", status)
        status = pjmedia_conf_add_port(self._obj, pjsip_endpoint._pool, self._tonegen, NULL, &self._tonegen_slot)
        if status != 0:
            raise PJSIPError("Could not connect DTMF tone generator to conference bridge", status)
        self._connect_playback_slot(self._tonegen_slot)

    cdef object _get_sound_devices(self, int is_playback):
        global _dummy_sound_dev_name
        cdef int i
        cdef int count
        cdef pjmedia_snd_dev_info_ptr_const info
        retval = [_dummy_sound_dev_name]
        for i from 0 <= i < pjmedia_snd_get_dev_count():
            info = pjmedia_snd_get_dev_info(i)
            if is_playback:
                count = info.output_count
            else:
                count = info.input_count
            if count:
                retval.append(info.name)
        return retval

    cdef int _find_sound_device(self, object device_name, int is_playback) except -1:
        global _dummy_sound_dev_name
        cdef int i
        cdef pjmedia_snd_dev_info_ptr_const info
        if device_name == _dummy_sound_dev_name:
            return -2
        for i from 0 <= i < pjmedia_snd_get_dev_count():
            info = pjmedia_snd_get_dev_info(i)
            if info.name == device_name:
                if (is_playback and info.output_count) or (not is_playback and info.input_count):
                    return i
        raise SIPCoreError('Sound device not found: "%s"' % device_name)

    cdef object _get_current_device(self, int is_playback):
        global _dummy_sound_dev_name
        cdef pjmedia_snd_stream_info snd_info
        cdef pjmedia_snd_dev_info_ptr_const dev_info
        cdef int dev_id
        cdef int status
        if self._master_port != NULL:
            return _dummy_sound_dev_name
        if self._snd == NULL:
            return None
        status = pjmedia_snd_stream_get_info(pjmedia_snd_port_get_snd_stream(self._snd), &snd_info)
        if status != 0:
            raise PJSIPError("Could not get sounds device info", status)
        if is_playback:
            dev_id = snd_info.play_id
        else:
            dev_id = snd_info.rec_id
        if dev_id == -1:
            return None
        else:
            dev_info = pjmedia_snd_get_dev_info(dev_id)
            return dev_info.name

    cdef int _set_sound_devices(self, int playback_index, int recording_index, unsigned int tail_length) except -1:
        global _dummy_sound_dev_name
        cdef int status
        if playback_index == -1 and len(self._get_sound_devices(1)) == 1:
            playback_index = -2
        if recording_index == -1 and len(self._get_sound_devices(0)) == 1:
            recording_index = -2
        if (playback_index == -2) ^ (recording_index == -2):
            raise ValueError('Either both playback and recording devices should be "%s" or neither' %
                             _dummy_sound_dev_name)
        self._destroy_snd_dev()
        self._pool = pjsip_endpt_create_pool(self._pjsip_endpoint, "conf_bridge", 4096, 4096)
        if self._pool == NULL:
            raise SIPCoreError("Could not allocate memory pool")
        if playback_index == -2:
            status = pjmedia_master_port_create(self._pool, self._null_port, pjmedia_conf_get_master_port(self._obj),
                                                0, &self._master_port)
            if status != 0:
                self._destroy_snd_dev()
                raise PJSIPError("Could not create master port for dummy sound device", status)
            status = pjmedia_master_port_start(self._master_port)
            if status != 0:
                self._destroy_snd_dev()
                raise PJSIPError("Could not start master port for dummy sound device", status)
        else:
            status = pjmedia_snd_port_create(self._pool, recording_index, playback_index,
                                             self._pjmedia_endpoint._sample_rate * 1000, 1,
                                             self._pjmedia_endpoint._sample_rate * 20, 16, 0, &self._snd)
            if status != 0:
                raise PJSIPError("Could not create sound device", status)
            status = pjmedia_snd_port_set_ec(self._snd, self._pool, tail_length, 0)
            if status != 0:
                self._destroy_snd_dev()
                raise PJSIPError("Could not set echo cancellation", status)
            status = pjmedia_snd_port_connect(self._snd, pjmedia_conf_get_master_port(self._obj))
            if status != 0:
                self._destroy_snd_dev()
                raise PJSIPError("Could not connect sound device", status)
        return 0

    cdef int _destroy_snd_dev(self) except -1:
        if self._snd != NULL:
            pjmedia_snd_port_destroy(self._snd)
            self._snd = NULL
        if self._master_port != NULL:
            pjmedia_master_port_destroy(self._master_port, 0)
            self._master_port = NULL
        if self._pool != NULL:
            pjsip_endpt_release_pool(self._pjsip_endpoint, self._pool)
            self._pool = NULL
        return 0

    def __dealloc__(self):
        self._destroy_snd_dev()
        if self._tonegen != NULL:
            self._disconnect_slot(self._tonegen_slot)
            pjmedia_tonegen_stop(self._tonegen)
            pjmedia_conf_remove_port(self._obj, self._tonegen_slot)
            self._tonegen = NULL
        if self._null_port != NULL:
            pjmedia_port_destroy(self._null_port)
            self._null_port = NULL
        if self._obj != NULL:
            pjmedia_conf_destroy(self._obj)
            self._obj = NULL

    cdef int _connect_playback_slot(self, unsigned int slot) except -1:
        cdef unsigned int output_slot
        cdef int status
        self._pb_in_slots.append(slot)
        for output_slot in self._all_out_slots:
            if slot == output_slot:
                continue
            status = pjmedia_conf_connect_port(self._obj, slot, output_slot, 0)
            if status != 0:
                raise PJSIPError("Could not connect audio stream to conference bridge", status)
        return 0

    cdef int _connect_output_slot(self, unsigned int slot) except -1:
        cdef unsigned int input_slot
        cdef int status
        self._all_out_slots.append(slot)
        for input_slot in self._pb_in_slots + self._conv_in_slots:
            if input_slot == slot:
                continue
            status = pjmedia_conf_connect_port(self._obj, input_slot, slot, 0)
            if status != 0:
                raise PJSIPError("Could not connect audio stream to conference bridge", status)
        return 0

    cdef int _connect_conv_slot(self, unsigned int slot) except -1:
        cdef unsigned int other_slot
        cdef int status
        self._conv_in_slots.append(slot)
        self._conv_out_slots.append(slot)
        for other_slot in self._conv_in_slots:
            if other_slot == slot:
                continue
            status = pjmedia_conf_connect_port(self._obj, other_slot, slot, 0)
            if status != 0:
                raise PJSIPError("Could not connect audio stream to conference bridge", status)
        for other_slot in self._all_out_slots + self._conv_out_slots:
            if slot == other_slot:
                continue
            status = pjmedia_conf_connect_port(self._obj, slot, other_slot, 0)
            if status != 0:
                raise PJSIPError("Could not connect audio stream to conference bridge", status)
        return 0

    cdef int _disconnect_slot(self, unsigned int slot) except -1:
        cdef unsigned int other_slot
        if slot in self._pb_in_slots:
            self._pb_in_slots.remove(slot)
            for other_slot in self._all_out_slots:
                pjmedia_conf_disconnect_port(self._obj, slot, other_slot)
        elif slot in self._all_out_slots:
            self._all_out_slots.remove(slot)
            for other_slot in self._pb_in_slots + self._conv_in_slots:
                pjmedia_conf_disconnect_port(self._obj, other_slot, slot)
        elif slot in self._conv_in_slots:
            self._conv_in_slots.remove(slot)
            self._conv_out_slots.remove(slot)
            for other_slot in self._conv_in_slots:
                pjmedia_conf_disconnect_port(self._obj, other_slot, slot)
            for other_slot in self._all_out_slots + self._conv_out_slots:
                pjmedia_conf_disconnect_port(self._obj, slot, other_slot)
        return 0

    cdef int _playback_dtmf(self, char digit) except -1:
        cdef pjmedia_tone_digit tone
        cdef int status
        if not self._do_playback_dtmf:
            return 0
        tone.digit = digit
        tone.on_msec = 200
        tone.off_msec = 50
        tone.volume = 0
        status = pjmedia_tonegen_play_digits(self._tonegen, 1, &tone, 0)
        if status != 0 and status != PJ_ETOOMANY:
            raise PJSIPError("Could not playback DTMF tone", status)
        return 0

    cdef int _play_tones(self, object tones) except -1:
        cdef int freq1, freq2, duration
        cdef pjmedia_tone_desc tones_arr[PJMEDIA_TONEGEN_MAX_DIGITS]
        cdef unsigned int count = 0
        cdef int status
        for freq1, freq2, duration in tones:
            if freq1 == 0 and count > 0:
                tones_arr[count-1].off_msec += duration
            else:
                if count >= PJMEDIA_TONEGEN_MAX_DIGITS:
                    raise SIPCoreError("Too many tones")
                tones_arr[count].freq1 = freq1
                tones_arr[count].freq2 = freq2
                tones_arr[count].on_msec = duration
                tones_arr[count].off_msec = 0
                tones_arr[count].volume = 0
                tones_arr[count].flags = 0
                count += 1
        if count > 0:
            status = pjmedia_tonegen_play(self._tonegen, count, tones_arr, 0)
            if status != 0:
                raise PJSIPError("Could not playback tones", status)
        return 0


cdef class RecordingWaveFile:
    cdef pj_pool_t *_pool
    cdef pjmedia_port *_port
    cdef int _slot
    cdef readonly ConferenceBridge conference_bridge
    cdef readonly str file_name
    cdef int _was_started

    def __cinit__(self, *args, **kwargs):
        self._slot = -1

    def __init__(self, ConferenceBridge conference_bridge, str file_name):
        if self.file_name is not None:
            raise SIPCoreError("RecordingWaveFile.__init__() was already called")
        if conference_bridge is None:
            raise ValueError("conference_bridge argument may not be None")
        if file_name is None:
            raise ValueError("file_name argument may not be None")
        self.conference_bridge = conference_bridge
        self.file_name = file_name

    cdef PJSIPUA _check_ua(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
            return ua
        except:
            self._pool = NULL
            self._port = NULL
            self._slot = -1

    property is_active:

        def __get__(self):
            self._check_ua()
            return self._port != NULL

    property slot:

        def __get__(self):
            if self._slot == -1:
                return None
            else:
                return self._slot

    def start(self):
        cdef int status
        cdef str pool_name = "RecordingWaveFile_%d" % id(self)
        cdef PJSIPUA ua = _get_ua()
        if self._was_started:
            raise SIPCoreError("This RecordingWaveFile was already started once")
        self._pool = pjsip_endpt_create_pool(ua._pjsip_endpoint._obj, pool_name, 4096, 4096)
        if self._pool == NULL:
            raise SIPCoreError("Could not allocate memory pool")
        try:
            status = pjmedia_wav_writer_port_create(self._pool, self.file_name,
                                                    self.conference_bridge.sample_rate, 1,
                                                    self.conference_bridge.sample_rate / 50, 16,
                                                    PJMEDIA_FILE_WRITE_PCM, 0, &self._port)
            if status != 0:
                raise PJSIPError("Could not create WAV file", status)
            self._slot = self.conference_bridge._add_port(ua, self._pool, self._port)
        except:
            self.stop()
            raise
        self._was_started = 1

    def stop(self):
        cdef PJSIPUA ua = self._check_ua()
        self._stop(ua)

    cdef int _stop(self, PJSIPUA ua) except -1:
        if self._slot != -1:
            self.conference_bridge._remove_port(ua, self._slot)
            self._slot = -1
        if self._port != NULL:
            pjmedia_port_destroy(self._port)
            self._port = NULL
        if self._pool != NULL:
            pjsip_endpt_release_pool(ua._pjsip_endpoint._obj, self._pool)
            self._pool = NULL
        return 0

    def __dealloc__(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
        except:
            return
        self._stop(ua)


cdef class WaveFile:
    cdef pj_pool_t *_pool
    cdef pjmedia_port *_port
    cdef int _slot
    cdef readonly ConferenceBridge conference_bridge
    cdef readonly str file_name
    cdef int _volume

    def __cinit__(self, *args, **kwargs):
        self._slot = -1
        self._volume = 100

    def __init__(self, ConferenceBridge conference_bridge, str file_name):
        if self.file_name is not None:
            raise SIPCoreError("WaveFile.__init__() was already called")
        if conference_bridge is None:
            raise ValueError("conference_bridge argument may not be None")
        if file_name is None:
            raise ValueError("file_name argument may not be None")
        self.conference_bridge = conference_bridge
        self.file_name = file_name

    cdef PJSIPUA _check_ua(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
            return ua
        except:
            self._pool = NULL
            self._port = NULL
            self._slot = -1

    property is_active:

        def __get__(self):
            self._check_ua()
            return self._port != NULL

    property slot:

        def __get__(self):
            if self._slot == -1:
                return None
            else:
                return self._slot

    property volume:

        def __get__(self):
            return self._volume

        def __set__(self, value):
            cdef int status
            cdef PJSIPUA ua = self._check_ua()
            if value < 0:
                raise ValueError("volume attribute cannot be negative")
            if ua is not None and self._slot != -1:
                status = pjmedia_conf_adjust_rx_level(self.conference_bridge._obj, self._slot, int(value * 1.28 - 128))
                if status != 0:
                    raise PJSIPError("Could not set volume of .wav file", status)
            self._volume = value

    def start(self):
        cdef str pool_name
        cdef int status
        cdef PJSIPUA ua = _get_ua()
        if self._port != NULL:
            raise SIPCoreError("WAV file is already playing")
        pool_name = "WaveFile_%d" % id(self)
        self._pool = pjsip_endpt_create_pool(ua._pjsip_endpoint._obj, pool_name, 4096, 4096)
        if self._pool == NULL:
            raise SIPCoreError("Could not allocate memory pool")
        try:
            status = pjmedia_wav_player_port_create(self._pool, self.file_name, 0, PJMEDIA_FILE_NO_LOOP, 0, &self._port)
            if status != 0:
                raise PJSIPError("Could not open WAV file", status)
            status = pjmedia_wav_player_set_eof_cb(self._port, <void *> self, cb_play_wav_eof)
            if status != 0:
                raise PJSIPError("Could not set WAV EOF callback", status)
            self._slot = self.conference_bridge._add_port(ua, self._pool, self._port)
            if self._volume != 100:
                self.volume = self._volume
        except:
            self.stop(ua, 0)
            raise

    cdef int _stop(self, PJSIPUA ua, int notify) except -1:
        cdef int status
        cdef int was_active = 0
        if self._slot != -1:
            was_active = 1
            self.conference_bridge._remove_port(ua, self._slot)
            self._slot = -1
        if self._port != NULL:
            pjmedia_port_destroy(self._port)
            self._port = NULL
            was_active = 1
        if self._pool != NULL:
            pjsip_endpt_release_pool(ua._pjsip_endpoint._obj, self._pool)
            self._pool = NULL
        if notify and was_active:
            _add_event("WaveFileDidFinishPlaying", dict(obj=self))

    def stop(self):
        cdef PJSIPUA ua = self._check_ua()
        self._stop(ua, 1)

    def __dealloc__(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
        except:
            return
        self._stop(ua, 0)


# callback functions

cdef int _ConferenceBridge_stop_sound_post(object obj) except -1:
    cdef ConferenceBridge conf_bridge = obj
    cdef PJSIPUA ua = conf_bridge._get_ua(0)
    if conf_bridge.used_slot_count == 0:
        conf_bridge._stop_sound_device(ua)

cdef void _ToneGenerator_cb_check_done(pj_timer_heap_t *timer_heap, pj_timer_entry *entry) with gil:
    cdef PJSIPUA ua
    cdef ToneGenerator tone_generator
    cdef int status
    try:
        ua = _get_ua()
    except:
        return
    try:
        if entry.user_data != NULL:
            tone_generator = <object> entry.user_data
            tone_generator._timer_active = 0
            if pjmedia_tonegen_is_busy(tone_generator._obj):
                tone_generator._start_timer(ua)
            else:
                _add_event("ToneGeneratorDidFinishPlaying", dict(obj=tone_generator))
    except:
        ua._handle_exception(1)

cdef int cb_play_wav_eof(pjmedia_port *port, void *user_data) with gil:
    cdef WaveFile wav_file
    cdef int status
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return 0
    try:
        ua = _get_ua()
        wav_file = <object> user_data
        wav_file._stop(ua, 1)
    except:
        ua._handle_exception(1)
    return 0

# globals

cdef object _dummy_sound_dev_name = "Dummy"
