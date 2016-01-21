// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include <stdlib.h>

#include <cmsis_os.h>
#include <stm32746g_discovery.h>
#include <stm32746g_discovery_lcd.h>

#include "include/fletch_api.h"
#include "include/static_ffi.h"

#include "platforms/stm/disco_fletch/src/fletch_entry.h"
#include "platforms/stm/disco_fletch/src/logger.h"
#include "platforms/stm/disco_fletch/src/page_allocator.h"
#include "platforms/stm/disco_fletch/src/uart.h"

#include "src/shared/platform.h"

extern unsigned char _binary_event_handler_test_snapshot_start;
extern unsigned char _binary_event_handler_test_snapshot_end;
extern unsigned char _binary_event_handler_test_snapshot_size;

extern PageAllocator* page_allocator;

// `MessageQueueProducer` will send a message every `kMessageFrequency`
// millisecond.
const int kMessageFrequency = 400;

// Sends a message on a port_id with a fixed interval.
static void MessageQueueProducer(const void *argument) {
  int device_id = reinterpret_cast<int>(argument);
  fletch::Device *device = fletch::GetDevice(device_id);
  uint16_t counter = 0;
  for (;;) {
    counter++;
    device->AddFlag(1);
    int status = fletch::SendMessageCmsis(device_id);
    if (status != osOK) {
      LOG_DEBUG("Error Sending %d\n", status);
    }
    osDelay(kMessageFrequency);
  }
}

void NotifyRead(int device_id) {
  fletch::Device *device = fletch::GetDevice(device_id);
  device->RemoveFlag(1);
}

int InitializeProducer() {
  fletch::Device *device = new fletch::Device(NULL, 0, 0, NULL);

  osThreadDef(PRODUCER, MessageQueueProducer, osPriorityNormal, 0, 2 * 1024);
  osThreadCreate(osThread(PRODUCER), NULL);

  return fletch::InstallDevice(device);
}

FLETCH_EXPORT_TABLE_BEGIN
  FLETCH_EXPORT_TABLE_ENTRY("BSP_LED_On", BSP_LED_On)
  FLETCH_EXPORT_TABLE_ENTRY("BSP_LED_Off", BSP_LED_Off)
  FLETCH_EXPORT_TABLE_ENTRY("initialize_producer", InitializeProducer)
  FLETCH_EXPORT_TABLE_ENTRY("notify_read", NotifyRead)
FLETCH_EXPORT_TABLE_END

// Run fletch on the linked in snapshot.
void StartFletch(void const * argument) {
  LOG_DEBUG("Setup fletch\n");
  FletchSetup();
  LOG_DEBUG("Read fletch snapshot\n");
  unsigned char *snapshot = &_binary_event_handler_test_snapshot_start;
  int snapshot_size =
      reinterpret_cast<int>(&_binary_event_handler_test_snapshot_size);
  FletchProgram program = FletchLoadSnapshot(snapshot, snapshot_size);
  LOG_DEBUG("Run fletch program\n");
  FletchRunMain(program);
  LOG_DEBUG("Fletch program exited\n");
}

// Main entry point from FreeRTOS. Running in the default task.
void FletchEntry(void const * argument) {
  // Add an arena of the 8Mb of external memory.
  uint32_t ext_mem_arena =
      page_allocator->AddArena("ExtMem", 0xc0000000, 0x800000);
  BSP_LED_Init(LED1);

  // Initialize the LCD.
  size_t fb_bytes = (RK043FN48H_WIDTH * RK043FN48H_HEIGHT * 2);
  size_t fb_pages = page_allocator->PagesForBytes(fb_bytes);
  void* fb = page_allocator->AllocatePages(fb_pages, ext_mem_arena);
  LOG_DEBUG("fb: %08x %08x %p\n", fb_bytes, fb_pages, fb);
  BSP_LCD_Init();
  BSP_LCD_LayerDefaultInit(1, reinterpret_cast<uint32_t>(fb));
  BSP_LCD_SelectLayer(1);
  BSP_LCD_SetFont(&LCD_DEFAULT_FONT);

  Logger::Create();

  fletch::Platform::Setup();
  osThreadDef(START_FLETCH, StartFletch, osPriorityNormal, 0,
              3 * 1024 /* stack size */);
  osThreadCreate(osThread(START_FLETCH), NULL);

  // No more to do right now.
  for (;;) {
    osDelay(1);
  }
}
