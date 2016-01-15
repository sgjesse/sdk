// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#ifndef PLATFORMS_STM_DISCO_FLETCH_SRC_UART_H_
#define PLATFORMS_STM_DISCO_FLETCH_SRC_UART_H_

#include <inttypes.h>

#include <cmsis_os.h>
#include <stm32f7xx_hal.h>

#include "platforms/stm/disco_fletch/src/circular_buffer.h"

#include "src/shared/platform.h"

// Interface to the universal asynchronous receiver/transmitter
// (UART).
class Uart {
 public:
  // Access the UART on the first UART port.
  Uart();

  // Opens the uart. Returns the port id used for listening.
  int Open();

  // Reads up to `count` bytes from the UART into `buffer` starting at
  // buffer. Returns the number of bytes read.
  //
  // This is non-blocking, and will return 0 if no data is available.
  size_t Read(uint8_t* buffer, size_t count);

  // Reads up to `count` bytes from the UART into `buffer` starting at
  // buffer. Returns the number of bytes written.
  //
  // This is non-blocking, and will return 0 if no data could be written.
  size_t Write(uint8_t* buffer, size_t count);

  void Task();

  void EnsureTransmission();

 private:
  static const int kTxBlockSize = 10;

  bool readyToRead_;
  bool readyToWrite_;

  uint8_t read_data_;
  CircularBuffer* read_buffer_;
  CircularBuffer* write_buffer_;

  int port_id_ = 0;

  UART_HandleTypeDef* uart_;

  void SendMessage(uint64_t message, uint32_t mask);

  fletch::Device device;

  friend void ReturnFromInterrupt(UART_HandleTypeDef *huart, uint32_t flag);

  // Transmit status.
  fletch::Mutex* tx_mutex_;
  uint8_t tx_data_[kTxBlockSize];  // Buffer send to the HAL.
  bool tx_pending_;
  CircularBuffer* tx_buffer_;

  friend void __UartTask(const void*);
};

Uart *GetUart(int port_id);

#endif  // PLATFORMS_STM_DISCO_FLETCH_SRC_UART_H_
