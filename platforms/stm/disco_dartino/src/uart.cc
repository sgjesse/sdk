// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "platforms/stm/disco_dartino/src/uart.h"

#include <stdlib.h>

#include <stm32f7xx_hal.h>

#include "src/shared/atomic.h"
#include "src/shared/utils.h"
#include "src/shared/platform.h"

#include "src/vm/hash_map.h"

// Reference to the instance in the code generated by STM32CubeMX.
extern UART_HandleTypeDef huart1;

// Bits set from the interrupt handler.
const int kReceivedBit = 1 << 0;
const int kTransmittedBit = 1 << 1;
const int kErrorBit = 1 << 3;

const int kRxBufferSize = 511;
const int kTxBufferSize = 511;

Uart *uart1;

Uart::Uart() : device_(this) {
  uart_ = &huart1;
  read_buffer_ = new CircularBuffer(kRxBufferSize);
  write_buffer_ = new CircularBuffer(kTxBufferSize);
  tx_pending_ = false;
  tx_mutex_ = dartino::Platform::CreateMutex();
}

static void UartTask(const void *arg) {
  const_cast<Uart*>(reinterpret_cast<const Uart*>(arg))->Task();
}

static void Initialize(UART_HandleTypeDef *uart) {
    // Enable the UART Parity Error Interrupt.
    __HAL_UART_ENABLE_IT(uart, UART_IT_PE);

    // Enable the UART Frame, Noise and Overrun Error Interrupts.
    __HAL_UART_ENABLE_IT(uart, UART_IT_ERR);

    // Enable the UART Data Register not empty Interrupt.
    __HAL_UART_ENABLE_IT(uart, UART_IT_RXNE);

    // TODO(sigurdm): Generalize when we support multiple UARTs.
    HAL_NVIC_EnableIRQ(USART1_IRQn);
}

int Uart::Open() {
  handle_ = dartino::DeviceManager::GetDeviceManager()->InstallDevice(&device_);
  uart1 = this;
  osThreadDef(UART_TASK, UartTask, osPriorityNormal, 0, 1024);
  signalThread_ =
      osThreadCreate(osThread(UART_TASK), reinterpret_cast<void*>(this));
  // Start receiving.
  Initialize(uart_);
  // We are ready to write.
  device_.SetFlag(kTransmittedBit);
  return handle_;
}

size_t Uart::Read(uint8_t* buffer, size_t count) {
  taskENTER_CRITICAL();
  int c = read_buffer_->Read(buffer, count);
  taskEXIT_CRITICAL();
  if (read_buffer_->IsEmpty()) {
    device_.ClearFlag(kReceivedBit);
  }
  return c;
}

size_t Uart::Write(const uint8_t* buffer, size_t offset, size_t count) {
  taskENTER_CRITICAL();
  size_t written_count =
      write_buffer_->Write(buffer + offset, count);
  taskEXIT_CRITICAL();
  if (written_count > 0) {
    dartino::ScopedLock lock(tx_mutex_);
    EnsureTransmission();
  }
  return written_count;
}

uint32_t Uart::GetError() {
  device_.ClearFlag(kErrorBit);
  return error_;
}

void Uart::Task() {
  // Process notifications from the interrupt handlers.
  for (;;) {
    // Wait for a signal.
    osEvent event = osSignalWait(0x0000FFFF, 0);

    if (event.status == osEventSignal) {
      uint32_t flags = event.value.signals;
      if ((flags & kTransmittedBit) != 0) {
        dartino::ScopedLock lock(tx_mutex_);
        EnsureTransmission();
      }
      // This will send a message on the event handler,
      // if there currently is an eligible listener.
      device_.SetFlag(flags);
    }
  }
}

void Uart::EnsureTransmission() {
  if (!tx_pending_) {
    taskENTER_CRITICAL();
    tx_length_ = write_buffer_->Read(tx_data_, kTxBlockSize);
    taskEXIT_CRITICAL();

    if (tx_length_ > 0) {
      tx_progress_ = 0;
      uart_->Instance->TDR = tx_data_[tx_progress_++] & 0xff;
      __HAL_UART_ENABLE_IT(uart_, UART_IT_TXE);

      tx_pending_ = true;
    }
  } else {
    if (write_buffer_->IsFull()) {
      device_.ClearFlag(kTransmittedBit);
    }
  }
}

Uart *GetUart(int handle) {
  return reinterpret_cast<Uart*>(
      dartino::DeviceManager::GetDeviceManager()->GetDevice(handle)->GetData());
}

void Uart::InterruptHandler() {
  uint32_t flags = 0;

  if ((__HAL_UART_GET_IT(uart_, UART_IT_PE) != RESET) &&
      (__HAL_UART_GET_IT_SOURCE(uart_, UART_IT_PE) != RESET)) {
    // Parity error
    __HAL_UART_CLEAR_PEFLAG(uart_);
    flags |= kErrorBit;
    error_ |= HAL_UART_ERROR_PE;
  }

  if ((__HAL_UART_GET_IT(uart_, UART_IT_FE) != RESET) &&
      (__HAL_UART_GET_IT_SOURCE(uart_, UART_IT_ERR) != RESET)) {
    __HAL_UART_CLEAR_FEFLAG(uart_);
    // Frame error
    __HAL_UART_CLEAR_PEFLAG(uart_);
    flags |= kErrorBit;
    error_ |= HAL_UART_ERROR_FE;
  }

  if ((__HAL_UART_GET_IT(uart_, UART_IT_NE) != RESET) &&
      (__HAL_UART_GET_IT_SOURCE(uart_, UART_IT_ERR) != RESET)) {
      __HAL_UART_CLEAR_NEFLAG(uart_);
    // Noise error
    flags |= kErrorBit;
    error_ |= HAL_UART_ERROR_NE;
  }

  if ((__HAL_UART_GET_IT(uart_, UART_IT_ORE) != RESET) &&
      (__HAL_UART_GET_IT_SOURCE(uart_, UART_IT_ERR) != RESET)) {
    __HAL_UART_CLEAR_OREFLAG(uart_);
    // Overrun
    flags |= kErrorBit;
    error_ |= HAL_UART_ERROR_ORE;
  }

  if ((__HAL_UART_GET_IT(uart_, UART_IT_RXNE) != RESET) &&
      (__HAL_UART_GET_IT_SOURCE(uart_, UART_IT_RXNE) != RESET)) {
    // Incoming character
    uint8_t byte = (uint8_t)(uart_->Instance->RDR & 0xff);
    if (read_buffer_->Write(&byte, 1) != 1) {
      // Buffer overflow. Ignored.
    }

    // Clear RXNE interrupt flag. Now the UART can receive another byte.
    __HAL_UART_SEND_REQ(uart_, UART_RXDATA_FLUSH_REQUEST);
    flags |= kReceivedBit;
  }

  if ((__HAL_UART_GET_IT(uart_, UART_IT_TXE) != RESET) &&
      (__HAL_UART_GET_IT_SOURCE(uart_, UART_IT_TXE) != RESET)) {
    // Transmit data empty, write next char.
    if (tx_progress_ < tx_length_) {
      uart_->Instance->TDR = tx_data_[tx_progress_++];
    } else {
      // No more data. Disable the UART Transmit Data Register Empty Interrupt.
      __HAL_UART_DISABLE_IT(uart_, UART_IT_TXE);

      flags |= kTransmittedBit;
      tx_pending_ = false;
    }
  }

  if ((__HAL_UART_GET_IT(uart_, UART_IT_TC) != RESET) &&
      (__HAL_UART_GET_IT_SOURCE(uart_, UART_IT_TC) != RESET)) {
    // Transmission complete.
  }

  // Send a signal to the listening thread.
  osSignalSet(signalThread_, flags);
}


extern "C" void USART1_IRQHandler(void) {
  uart1->InterruptHandler();
}
