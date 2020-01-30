# Copyright 2020 Jetperch LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


from .decimators import DECIMATORS
from .filter_fir cimport FilterFir, filter_fir_cbk
STREAM_BUFFER_REDUCTIONS = [200, 100, 50]  # in samples in sample units of the previous reduction
STREAM_BUFFER_DURATION = 1.0  # seconds


DS_NP_VALUE_FORMAT = ['f4', 'f4', 'f4', 'u1', 'u1', 'u1', 'u1']
DS_VALUE_DTYPE = np.dtype({'names': STATS_FIELD_NAMES + ['rsv1'], 'formats': DS_NP_VALUE_FORMAT})
cdef uint32_t _DS_NP_LENGTH_C = _STATS_FIELDS + 1


cdef struct ds_value_s:
    float current
    float voltage
    float power
    uint8_t current_range
    uint8_t current_lsb
    uint8_t voltage_lsb
    uint8_t rsv1


assert(sizeof(ds_value_s) == 16)


cdef class DownsamplingStreamBuffer:

    cdef StreamBuffer _stream_buffer
    cdef double _output_sampling_frequency
    cdef uint64_t _length # in samples
    cdef uint64_t _processed_sample_id
    cdef uint64_t _process_idx
    cdef FilterFir _filter_fir
    cdef object _input_npy
    cdef double * _input_dbl
    cdef object _buffer_npy
    cdef ds_value_s * _buffer_ptr
    cdef uint64_t _accum[3]
    cdef uint64_t _downsample_m

    def __init__(self, duration, reductions, input_sampling_frequency, output_sampling_frequency):
        if input_sampling_frequency != 2000000:
            raise ValueError(f'Require 2000000 sps, provided {input_sampling_frequency}')
        if int(output_sampling_frequency) not in DECIMATORS:
            raise ValueError(f'Unsupported output frequency: {output_sampling_frequency}')
        self._output_sampling_frequency = int(output_sampling_frequency)
        self._downsample_m = input_sampling_frequency / self._output_sampling_frequency
        self._stream_buffer = StreamBuffer(STREAM_BUFFER_DURATION, STREAM_BUFFER_REDUCTIONS, input_sampling_frequency)
        self._stream_buffer.process_stats_callback_set(<stream_buffer_process_fn> self._stream_buffer_process_cbk, <void *> self)
        reduction_step = int(np.prod(reductions))
        length = int(duration * output_sampling_frequency)
        length = ((length + reduction_step - 1) // reduction_step) * reduction_step
        self._length = length

        self._buffer_npy = np.zeros(length, dtype=DS_VALUE_DTYPE)
        cdef ds_value_s [::1] _buffer_view = self._buffer_npy
        self._buffer_ptr = &_buffer_view[0]

        self._input_npy = np.zeros(_DS_NP_LENGTH_C, dtype=np.float64)
        cdef double [::1] _input_view = self._input_npy
        self._input_dbl = &_input_view[0]

        decimator = DECIMATORS[self._output_sampling_frequency]
        self._filter_fir = FilterFir(decimator, width=3)
        self._filter_fir.c_callback_set(<filter_fir_cbk> self._filter_fir_cbk, <void *> self)
        self.reset()

    def __len__(self):
        return len(self._stream_buffer)

    def __str__(self):
        return 'DownsamplingStreamBuffer(length=%d)' % (self._length)

    @property
    def sample_id_range(self):
        s_end = int(self._processed_sample_id)
        s_start = s_end - int(self._length)
        if s_start < 0:
            s_start = 0
        return s_start, s_end

    @property
    def sample_id_max(self):
        # in units of input samples
        return self._stream_buffer.sample_id_max

    @sample_id_max.setter
    def sample_id_max(self, value):
        # in units of input samples
        self._stream_buffer.sample_id_max = value  # stop streaming when reach this sample

    @property
    def contiguous_max(self):
        # in units of input samples
        return self._stream_buffer.contiguous_max

    @contiguous_max.setter
    def contiguous_max(self, value):
        # in units of input samples
        self._stream_buffer.contiguous_max = value

    @property
    def callback(self):
        return self._stream_buffer.callback

    @callback.setter
    def callback(self, value):
        self._stream_buffer.callback = value

    @property
    def voltage_range(self):
        return self._stream_buffer.voltage_range

    @voltage_range.setter
    def voltage_range(self, value):
        self._stream_buffer.voltage_range = value

    @property
    def suppress_mode(self):
        return self._stream_buffer.suppress_mode

    @suppress_mode.setter
    def suppress_mode(self, value):
        self._stream_buffer.suppress_mode = value

    @property
    def sampling_frequency(self):
        return self._output_sampling_frequency

    @property
    def limits_time(self):
        return 0.0, len(self) / self._output_sampling_frequency

    @property
    def limits_samples(self):
        _, s_max = self.sample_id_range
        return (s_max - len(self)), s_max

    def time_to_sample_id(self, t):
        idx_start, idx_end = self.limits_samples
        t_start, t_end = self.limits_time
        return int(np.round((t - t_start) / (t_end - t_start) * (idx_end - idx_start) + idx_start))

    def sample_id_to_time(self, s):
        idx_start, idx_end = self.limits_samples
        t_start, t_end = self.limits_time
        return (s - idx_start) / (idx_end - idx_start) * (t_end - t_start) + t_start

    def status(self):
        return self._stream_buffer.status()

    def calibration_set(self, current_offset, current_gain, voltage_offset, voltage_gain):
        return self._stream_buffer.calibration_set(current_offset, current_gain, voltage_offset, voltage_gain)

    def reset(self):
        self._processed_sample_id = 0
        self._process_idx = 0
        self._stream_buffer.reset()
        self._filter_fir.reset()
        for idx in range(len(self._accum)):
            self._accum[idx] = 0

    cpdef insert(self, data):
        return self._stream_buffer.insert(data)

    cpdef insert_raw(self, data):
        return self._stream_buffer.insert_raw(data)

    @staticmethod
    cdef void _stream_buffer_process_cbk(void * user_data, float cal_i, float cal_v, uint8_t bits):
        cdef DownsamplingStreamBuffer self = <object> user_data
        self._input_dbl[0] = <double> cal_i
        self._input_dbl[1] = <double> cal_v
        self._input_dbl[2] = <double> cal_i * cal_v
        self._accum[0] += bits & 0x0f  # current_range
        self._accum[1] += (bits & 0x10) >> 4  # current_lsb
        self._accum[2] += (bits & 0x20) >> 5  # voltage_lsb
        self._filter_fir.c_process(self._input_dbl, 3)  # todo _DS_NP_LENGTH_C

    @staticmethod
    cdef void _filter_fir_cbk(void * user_data, const double * y, uint32_t y_length):
        cdef DownsamplingStreamBuffer self = <object> user_data
        cdef ds_value_s * v = &self._buffer_ptr[self._process_idx]
        v.current = <float> y[0]
        v.voltage = <float> y[1]
        v.power = <float> y[2]
        v.current_range = <uint8_t> ((self._accum[0] * 16) / self._downsample_m)
        v.current_lsb = <uint8_t> ((self._accum[1] * 255) / self._downsample_m)
        v.voltage_lsb = <uint8_t>((self._accum[2] * 255) / self._downsample_m)
        self._process_idx += 1
        self._processed_sample_id += 1
        if self._process_idx >= self._length:
            self._process_idx = 0

    def process(self):
        self._stream_buffer.process()

    cdef int _range_check(self, uint64_t start, uint64_t stop):
        if stop <= start:
            log.warning("js_stream_buffer_get stop <= start")
            return 0
        if start > self._processed_sample_id:
            log.warning("js_stream_buffer_get start newer that current")
            return 0
        if stop > self._processed_sample_id:
            log.warning("js_stream_buffer_get stop newer than current")
            return 0
        return 1

    def statistics_get(self, start, stop, out=None):
        cdef c_running_statistics.statistics_s * out_ptr
        if out is None:
            out = _stats_factory(NULL)
        out_ptr = _stats_ptr(out)
        # todo populate
        return out

    cdef uint64_t _data_get(self, c_running_statistics.statistics_s *buffer, uint64_t buffer_samples,
                            int64_t start, int64_t stop, uint64_t increment):
        """Get the summarized statistics over a range.
        
        :param buffer: The N x _STATS_FIELDS buffer to populate.
        :param buffer_samples: The value of N of the buffer_ptr (effective buffer length).
        :param start: The starting sample id (inclusive).
        :param stop: The ending sample id (exclusive).
        :param increment: The number of raw samples.
        :return: The number of samples placed into buffer.
        """
        cdef uint64_t buffer_samples_orig = buffer_samples
        cdef uint8_t i
        cdef int64_t idx
        cdef int64_t data_offset
        cdef c_running_statistics.statistics_s stats[_STATS_FIELDS]
        cdef uint64_t fill_count = 0
        cdef uint64_t fill_count_tmp
        cdef uint64_t samples_per_step
        cdef uint64_t samples_per_step_next
        cdef uint64_t length
        cdef int64_t idx_start
        cdef int64_t end_gap
        cdef int64_t start_orig = start
        cdef uint64_t n
        cdef c_running_statistics.statistics_s * out_ptr
        cdef c_running_statistics.statistics_s * b
        cdef ds_value_s * v

        if (stop + self._length) < self._processed_sample_id:
            fill_count = buffer_samples_orig  # too old, no data
        elif start < 0:
            # round to floor, absolute value
            fill_count_tmp = ((-start + increment - 1) // increment)
            start += fill_count_tmp * increment
            #log.info('_data_get start < 0: %d [%d] => %d', start_orig, fill_count_tmp, start)
            fill_count += fill_count_tmp

        if not self._range_check(start, stop):
            return 0

        if (start + self._length) < self._processed_sample_id:
            fill_count_tmp = (self._processed_sample_id - (start + self._length)) // increment
            start += fill_count_tmp * increment
            #log.info('_data_get behind < 0: %d [%d] => %d', start_orig, fill_count_tmp, start)
            fill_count += fill_count_tmp

        # Fill in too old of data with NAN
        for n in range(fill_count):
            if buffer_samples == 0:
                log.warning('_data_get filled with NaN %d of %d', buffer_samples_orig, fill_count)
                return buffer_samples_orig
            _stats_invalidate(buffer)
            buffer_samples -= 1
            buffer += _STATS_FIELDS
        if buffer_samples != buffer_samples_orig:
            log.debug('_data_get filled %s', buffer_samples_orig - buffer_samples)

        if increment <= 1:
            # direct copy
            idx = start % self._length
            while start != stop and buffer_samples:
                v = self._buffer_ptr + idx
                for b in buffer[:_STATS_FIELDS]:
                    b.k = 1
                    b.s = 0.0
                    b.min = NAN
                    b.max = NAN
                buffer[0].m = v.current
                buffer[1].m = v.voltage
                buffer[2].m = v.power
                buffer[3].m = (<double> v.current_range) * (1.0 / 16)
                buffer[4].m = (<double> v.current_lsb) * (1.0 / 255)
                buffer[5].m = (<double> v.voltage_lsb) * (1.0 / 255)
                buffer_samples -= 1
                idx += 1
                start += 1
                buffer += _STATS_FIELDS
                if idx >= <int64_t> self._length:
                    idx = 0
        return buffer_samples_orig - buffer_samples

    def data_get(self, start, stop, increment=None, out=None):
        # The np.ndarray((N, STATS_FIELD_COUNT), dtype=DTYPE) data.
        cdef c_running_statistics.statistics_s * out_ptr
        increment = 1 if increment is None else int(increment)
        if start >= stop:
            log.info('data_get: start >= stop')
            return np.zeros((0, _STATS_FIELDS), dtype=STATS_DTYPE)
        expected_length = (stop - start) // increment
        if out is None:
            out = _stats_array_factory(expected_length, NULL)
        out_ptr = _stats_array_ptr(out)
        length = self._data_get(out_ptr, len(out), start, stop, increment)
        if length != expected_length:
            log.warning('length mismatch: expected=%s, returned=%s', expected_length, length)
        return out[:length, :]

    def samples_get(self, start, stop, fields=None):
        raise NotImplementedError()
