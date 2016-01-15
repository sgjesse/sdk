// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include <stdlib.h>

#include <cmsis_os.h>
#include <stm32746g_discovery.h>

#include "include/fletch_api.h"
#include "include/static_ffi.h"

#include "platforms/stm/disco_fletch/src/fletch_entry.h"
#include "platforms/stm/disco_fletch/src/logger.h"
#include "platforms/stm/disco_fletch/src/uart.h"

extern unsigned char _binary_snapshot_start;
extern unsigned char _binary_snapshot_end;
extern unsigned char _binary_snapshot_size;

extern "C" size_t UartRead(int port_id, uint8_t* buffer, size_t count) {
  return GetUart(port_id)->Read(buffer, count);
}

extern "C" size_t UartWrite(int port_id, uint8_t* buffer, size_t count) {
  return GetUart(port_id)->Write(buffer, count);
}

extern "C" size_t UartOpen(int port_id, uint8_t* buffer, size_t count) {
  Uart *uart = new Uart();
  return uart->Open();
}

FLETCH_EXPORT_TABLE_BEGIN
  FLETCH_EXPORT_TABLE_ENTRY("uart_read", UartRead)
  FLETCH_EXPORT_TABLE_ENTRY("uart_write", UartWrite)
  FLETCH_EXPORT_TABLE_ENTRY("uart_open", UartOpen)
  FLETCH_EXPORT_TABLE_ENTRY("BSP_LED_On", BSP_LED_On)
  FLETCH_EXPORT_TABLE_ENTRY("BSP_LED_Off", BSP_LED_Off)
FLETCH_EXPORT_TABLE_END

// Run fletch on the linked in snapshot.
void StartFletch(void const * argument) {
  LOG_DEBUG("Setup fletch\n");
  FletchSetup();
  LOG_DEBUG("Read fletch snapshot\n");
  unsigned char *snapshot = &_binary_snapshot_start;
  int snapshot_size =  reinterpret_cast<int>(&_binary_snapshot_size);
  FletchProgram program = FletchLoadSnapshot(snapshot, snapshot_size);
  LOG_DEBUG("Run fletch program\n");
  FletchRunMain(program);
  LOG_DEBUG("Fletch program exited\n");
}

// Main task entry point from FreeRTOS.
void FletchEntry(void const * argument) {
  BSP_LED_Init(LED1);

  Logger::Create();

  StartFletch(argument);

  // No more to do right now.
  for (;;) {
    osDelay(1);
  }
}
