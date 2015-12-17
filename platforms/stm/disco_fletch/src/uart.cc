// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "platforms/stm/disco_fletch/src/uart.h"

#include <stdlib.h>

#include <stm32f7xx_hal.h>

#include "platforms/stm/disco_fletch/src/logger.h"

#include "src/shared/atomic.h"

// Reference to the instance in the code generated by STM32CubeMX.
extern UART_HandleTypeDef huart1;

// TODO(sgjesse): Get rid of these global variables. These global
// variables are accessed from the interrupt handlers.
static osSemaphoreId sem_;
static uint32_t error = 0;

// Bits set from interrupt handlers.
const int kReceivedBit = 1 << 0;
const int kTransmittedBit = 1 << 1;
const int kErrorBit = 1 << 2;
static fletch::Atomic<uint32_t> interrupt_flags;

const int kRxBufferSize = 511;
const int kTxBufferSize = 511;

// C trampoline for the interrupt handling thread.
void __UartTask(void const* argument) {
  Uart* uart = const_cast<Uart*>(reinterpret_cast<const Uart*>(argument));
  uart->Task();
}

Uart::Uart() {
  uart_ = &huart1;
  rx_buffer_ = new CircularBuffer(kRxBufferSize);
  tx_mutex_ = fletch::Platform::CreateMutex();
  tx_buffer_ = new CircularBuffer(kTxBufferSize);
  tx_pending_ = false;
  error_count_ = 0;

  // Semaphore for signaling from interrupt handlers.  A maximum of
  // three tokens - one for data received and one for data transmitted
  // and one for error.
  semaphore_ = osSemaphoreCreate(osSemaphore(semaphore_def_), 3);
  // Store in global variable for access from interrupt handlers.
  sem_ = semaphore_;
}

void Uart::Start() {
  // Start thread for handling interrupts.
  osThreadDef(UART_TASK, __UartTask, osPriorityHigh, 0, 1024);
  osThreadCreate(osThread(UART_TASK), this);

  // Start receiving.
  HAL_UART_Receive_IT(uart_, &rx_data_, 1);
}

size_t Uart::Read(uint8_t* buffer, size_t count) {
  return rx_buffer_->Read(buffer, count, CircularBuffer::kBlock);
}

size_t Uart::Write(uint8_t* buffer, size_t count) {
  size_t written = tx_buffer_->Write(buffer, count, CircularBuffer::kBlock);

  fletch::ScopedLock lock(tx_mutex_);
  EnsureTransmission();
  return written;
}

void Uart::Task() {
  // Process notifications from the interrupt handlers.
  for (;;) {
    // Wait for an interrupt to be processed.
    osSemaphoreWait(semaphore_, osWaitForever);
    // Read the flags and set them to zero.
    uint32_t flags = interrupt_flags.exchange(0);

    if ((flags & kReceivedBit) != 0) {
      // Don't block when writing to the buffer. Buffer overrun will
      // cause lost data.
      rx_buffer_->Write(&rx_data_, 1, CircularBuffer::kDontBlock);

      // Start receiving of next byte.
      HAL_StatusTypeDef status = HAL_UART_Receive_IT(uart_, &rx_data_, 1);
      if (status != HAL_OK) {
        LOG_ERROR("%d\n", status);
      }
    }

    if ((flags & kTransmittedBit) != 0) {
      fletch::ScopedLock lock(tx_mutex_);
      tx_pending_ = false;
      EnsureTransmission();
    }

    if ((flags & kErrorBit) != 0) {
      // Ignore errors for now.
      error_count_++;
      error = 0;
      // Setup interrupt for next byte.
      HAL_StatusTypeDef status = HAL_UART_Receive_IT(uart_, &rx_data_, 1);
      if (status != HAL_OK) {
        LOG_ERROR("%d\n", status);
      }
    }
  }
}

void Uart::EnsureTransmission() {
  if (!tx_pending_) {
    // Don't block when there is nothing to send.
    int bytes = tx_buffer_->Read(
        tx_data_, kTxBlockSize, CircularBuffer::kDontBlock);
    if (bytes > 0) {
      HAL_StatusTypeDef status = HAL_UART_Transmit_IT(uart_, tx_data_, bytes);
      if (status != HAL_OK) {
        LOG_ERROR("%d\n", status);
      }
      tx_pending_ = true;
    }
  }
}

// Shared return from interrupt handler. Will set the specified flag
// and transfer control to the thread handling interrupts.
static void ReturnFromInterrupt(UART_HandleTypeDef *huart, uint32_t flag) {
  // Set the requested bit.
  uint32_t flags = interrupt_flags;
  uint32_t new_flags = flags |= flag;
  bool success = false;
  while (!success) {
    success =
        interrupt_flags.compare_exchange_weak(flags, new_flags);
  }

  // Pass control to the thread handling interrupts.
  portBASE_TYPE xHigherPriorityTaskWoken = pdFALSE;
  osSemaphoreRelease(sem_);
  portEND_SWITCHING_ISR(xHigherPriorityTaskWoken);
}

extern "C" void HAL_UART_RxCpltCallback(UART_HandleTypeDef *huart) {
  ReturnFromInterrupt(huart, kReceivedBit);
}

extern "C" void HAL_UART_TxCpltCallback(UART_HandleTypeDef *huart) {
  ReturnFromInterrupt(huart, kTransmittedBit);
}

extern "C" void HAL_UART_ErrorCallback(UART_HandleTypeDef *huart) {
  error = HAL_UART_GetError(huart);

  // Clear all errors.
  __HAL_UART_CLEAR_OREFLAG(&huart1);
  __HAL_UART_CLEAR_FEFLAG(&huart1);
  __HAL_UART_CLEAR_PEFLAG(&huart1);
  __HAL_UART_CLEAR_NEFLAG(&huart1);

  ReturnFromInterrupt(huart, kErrorBit);
}
