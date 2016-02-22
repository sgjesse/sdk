// Copyright (c) 2016, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#if 0
#include <stm32f7xx_hal.h>
#include <stm32746g_discovery_sdram.h>
#else
#include <stm32f4xx_hal.h>
#endif

#include <cmsis_os.h>
#include <FreeRTOS.h>
#include <task.h>

#include "src/shared/assert.h"

#include "platforms/stm/disco_dartino/src/cmpctmalloc.h"
#include "platforms/stm/disco_dartino/src/dartino_entry.h"
#include "platforms/stm/disco_dartino/src/page_allocator.h"

// Definition of functions in generated/Src/mx_main.c.
extern "C" {
#if 0
void SystemClock_Config(void);
void MX_GPIO_Init(void);
void MX_DCMI_Init(void);
void MX_DMA2D_Init(void);
void MX_FMC_Init(void);
void MX_ETH_Init(void);
void MX_I2C1_Init(void);
void MX_LTDC_Init(void);
void MX_QUADSPI_Init(void);
void MX_SDMMC1_SD_Init(void);
void MX_SPDIFRX_Init(void);
void MX_USART1_UART_Init(void);
#else
void SystemClock_Config(void);
void MX_GPIO_Init(void);
void MX_USART2_UART_Init(void);
#endif
}  // extern "C"

// This object is initialized during EarlyInit.
PageAllocator* page_allocator;

#define MAX_STACK_SIZE 0x2000

// Wrapping of the static initialization to configure the C/C++ heap
// first.
void EarlyInit();
extern "C" void __real___libc_init_array();
extern "C" void __wrap___libc_init_array() {
  EarlyInit();
  __real___libc_init_array();
}

// Wrapping of all malloc/free calls in newlib. This should cause the
// newlib malloc to never be used, and sbrk should never be called for
// memory.
extern "C" void *__wrap__malloc_r(struct _reent *reent, size_t size) {
  return pvPortMalloc(size);
}

extern "C" void *suspendingRealloc(void *ptr, size_t size);

extern "C" void *__wrap__realloc_r(
    struct _reent *reent, void *ptr, size_t size) {
  return suspendingRealloc(ptr, size);
}

extern "C" void *__wrap__calloc_r(
    struct _reent *reent, size_t nmemb, size_t size) {
  if (nmemb == 0 || size == 0) return NULL;
  size = nmemb * size;
  void *ptr = pvPortMalloc(size);
  memset(ptr, 0, size);
  return ptr;
}

extern "C" void __wrap__free_r(struct _reent *reent, void *ptr) {
  vPortFree(ptr);
}

// Early initialization before static initialization. This will
// configure the C/C++ heap.
void EarlyInit() {
  // Get the free location in system RAM just after the bss segment.
  extern char end asm("end");
  uintptr_t heap_start = reinterpret_cast<uintptr_t>(&end);

  // Reserve a map for 72 pages (256k + 16k + 16k) in .bss.
  const size_t kDefaultPageMapSize = 72;
  static uint8_t default_page_map[kDefaultPageMapSize];
  // Allocate a PageAllocator in system RAM.
  page_allocator = reinterpret_cast<PageAllocator*>(heap_start);
  page_allocator->Initialize();
  heap_start += sizeof(PageAllocator);
  // Use the NVIC offset register to locate the main stack pointer.
  uintptr_t min_stack_ptr =
      (uintptr_t) (*(unsigned int*) *(unsigned int*) 0xE000ED08);
  // Locate the stack bottom address.
  min_stack_ptr -= MAX_STACK_SIZE;
  // Add the system RAM as the initial arena.
  uint32_t arena_id = page_allocator->AddArena(
      "System RAM", heap_start, min_stack_ptr - heap_start,
      default_page_map, kDefaultPageMapSize);
  ASSERT(arena_id == 1);

  // Initialize the compact C/C++ heap implementation.
  cmpct_init();
}

extern "C" void* page_alloc(size_t pages) {
  return page_allocator->AllocatePages(pages);
}

extern "C" void page_free(void* start, size_t pages) {
  return page_allocator->FreePages(start, pages);
}

#if 0
static void ConfigureMPU() {
  // Disable the MPU for configuration.
  HAL_MPU_Disable();

  // Configure the MPU attributes as write-through for SRAM.
  MPU_Region_InitTypeDef MPU_InitStruct;
  MPU_InitStruct.Enable = MPU_REGION_ENABLE;
  MPU_InitStruct.BaseAddress = 0x20010000;
  MPU_InitStruct.Size = MPU_REGION_SIZE_256KB;
  MPU_InitStruct.AccessPermission = MPU_REGION_FULL_ACCESS;
  MPU_InitStruct.IsBufferable = MPU_ACCESS_NOT_BUFFERABLE;
  MPU_InitStruct.IsCacheable = MPU_ACCESS_CACHEABLE;
  MPU_InitStruct.IsShareable = MPU_ACCESS_NOT_SHAREABLE;
  MPU_InitStruct.Number = MPU_REGION_NUMBER0;
  MPU_InitStruct.TypeExtField = MPU_TEX_LEVEL0;
  MPU_InitStruct.SubRegionDisable = 0x00;
  MPU_InitStruct.DisableExec = MPU_INSTRUCTION_ACCESS_ENABLE;

  HAL_MPU_ConfigRegion(&MPU_InitStruct);

  // Enable the MPU with new configuration.
  HAL_MPU_Enable(MPU_PRIVILEGED_DEFAULT);
}

static void EnableCPUCache() {
  // Enable branch prediction.
  SCB->CCR |= (1 <<18);
  __DSB();

  // Enable I-Cache.
  SCB_EnableICache();

  // Enable D-Cache.
  SCB_EnableDCache();
}
#endif
int main() {
  // Configure the MPU attributes as Write Through.
  //  ConfigureMPU();

  // Enable the CPU Cache.
  //  EnableCPUCache();

  // Reset of all peripherals, and initialize the Flash interface and
  // the Systick.
  HAL_Init();

  // Configure the system clock. Thie functions is defined in
  // generated/Src/main.c.
  SystemClock_Config();

#if 0
  // Initialize all configured peripherals. These functions are
  // defined in generated/Src/mx_main.c. We are not calling
  // MX_FMC_Init, as BSP_SDRAM_Init will do all initialization of the
  // FMC.
  MX_GPIO_Init();
  MX_DCMI_Init();
  MX_DMA2D_Init();
  MX_ETH_Init();
  MX_I2C1_Init();
  MX_LTDC_Init();
  MX_QUADSPI_Init();
  MX_SDMMC1_SD_Init();
  MX_SPDIFRX_Init();
  MX_USART1_UART_Init();

  // Initialize the SDRAM (including FMC).
  BSP_SDRAM_Init();
#else
  MX_GPIO_Init();
  MX_USART2_UART_Init();
#endif

  osThreadDef(mainTask, DartinoEntry, osPriorityNormal, 0, 4 * 1024);
  osThreadId mainTaskHandle = osThreadCreate(osThread(mainTask), NULL);
  USE(mainTaskHandle);

  // Start the scheduler.
  osKernelStart();

  // We should never get as the scheduler should never terminate.
  FATAL("Returned from scheduler");
}
