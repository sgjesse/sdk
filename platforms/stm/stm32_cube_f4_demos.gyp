# Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE.md file.

{
  'variables': {
    'discovery_projects': '<(stm32_cube_f4)/Projects/STM32F4-Discovery',
    'nucleo_projects': '<(stm32_cube_f4)/Projects/STM32F411RE-Nucleo',
  },
  'target_defaults': {
    'include_dirs': [
      #'<(stm32_cube_f7)/Drivers/CMSIS/Include/',
      '<(stm32_cube_f4)/Drivers/CMSIS/Device/ST/STM32F4xx/Include/',
      '<(stm32_cube_f4)/Drivers/BSP/STM32F4-Discovery/',
      #'<(stm32_cube_f7)/Drivers/BSP/Components/Common/',
      '<(stm32_cube_f4)/Middlewares/ST/STM32_USB_Device_Library/Core/Inc',
      '<(stm32_cube_f4)/Middlewares/ST/STM32_USB_Device_Library/Class/HID/Inc/',
      #'<(stm32_cube_f7)/Middlewares/ST/STemWin/Config/',
      #'<(stm32_cube_f7)/Middlewares/ST/STemWin/inc/',
      #'<(stm32_cube_f7)/Middlewares/ST/STM32_USB_Device_Library/Core/Inc/',
      #'<(stm32_cube_f7)/Middlewares/ST/STM32_USB_Host_Library/Core/Inc/',
      #'<(stm32_cube_f7)/Middlewares/ST/STM32_USB_Host_Library/Class/MSC/Inc/',
      #'<(stm32_cube_f7)/Middlewares/Third_Party/FatFs/src/',
      #'<(stm32_cube_f7)/Middlewares/Third_Party/FatFs/src/drivers/',
      #'<(stm32_cube_f7)/Utilities/Log',
      #'<(stm32_cube_f7)/Utilities/Fonts',
      #'<(stm32_cube_f7)/Utilities/CPU',
    ],
    'cflags' : [
    #  '-Wno-empty-body',
    #  '-Wno-missing-field-initializers',
      '-Wno-sign-compare',
    ],
  },
  'targets': [
    {
      'target_name': 'Demonstrations.elf',
      'variables': {
        'project_name': 'Demonstrations',
        'project_path':
          '<(discovery_projects)/<(project_name)',
        'project_include_path': '<(project_path)/Inc/',
        'project_source_path': '<(project_path)/Src/',
        'ldflags': [
          '-specs=nosys.specs',
          '-specs=nano.specs',
          '-T<(project_path)/SW4STM32/STM32F4-DISCO/STM32F407VGTx_FLASH.ld',
        ],
      },
      'type': 'executable',
      'includes': [
        'stm32f4_hal_sources.gypi',
      ],
      'include_dirs': [
        '<(project_include_path)',
      ],
      'defines': [
        'STM32F407xx',
        'USE_STM32F4_DISCO',
      ],
      'sources': [
        # Application.
        '<(project_source_path)/main.c',
        '<(project_source_path)/stm32f4xx_hal_msp.c',
        '<(project_source_path)/usbd_conf.c',
        '<(project_source_path)/usbd_desc.c',

        # Board initialization and interrupt service routines.
        '<(project_source_path)/stm32f4xx_it.c',
        '<(project_source_path)/system_stm32f4xx.c',
        '<(project_path)/SW4STM32/startup_stm32f407xx.s',

        # Board support packages.
        '<(stm32_cube_f4_bsp_discovery)/stm32f4_discovery.c',

        '<(stm32_cube_f4)/Drivers/BSP/Components/lis302dl/lis302dl.c',
        '<(stm32_cube_f4)/Drivers/BSP/Components/lis3dsh/lis3dsh.c',
        '<(stm32_cube_f4)/Drivers/BSP/STM32F4-Discovery/stm32f4_discovery_accelerometer.c',

        # XXX
        '<(stm32_cube_f4)/Middlewares/ST/STM32_USB_Device_Library/Core/Src/usbd_core.c',
        '<(stm32_cube_f4)/Middlewares/ST/STM32_USB_Device_Library/Core/Src/usbd_ctlreq.c',
        '<(stm32_cube_f4)/Middlewares/ST/STM32_USB_Device_Library/Core/Src/usbd_ioreq.c',

        '<(stm32_cube_f4)/Middlewares/ST/STM32_USB_Device_Library/Class/HID/Src/usbd_hid.c',
      ],
      'conditions': [
        ['OS=="mac"', {
          'xcode_settings': {
            'OTHER_LDFLAGS': [
              '<@(ldflags)',
            ],
          },
        }],
        ['OS=="linux"', {
          'ldflags': [
            '<@(ldflags)',
          ],
        }],
      ],
    },
    {
      'variables': {
        'project_name': 'Demonstrations',
      },
      'type': 'none',
      'target_name': 'Demonstrations',
      'dependencies' : [
        'Demonstrations.elf'
      ],
      'actions': [
        {
          'action_name': 'generate_bin',
          'inputs': [
            '<(PRODUCT_DIR)/<(project_name).elf',
          ],
          'outputs': [
            '<(PRODUCT_DIR)/<(project_name).bin',
          ],
          'action': [
            '<(objcopy)',
            '-O',
            'binary',
            '<(PRODUCT_DIR)/<(project_name).elf',
            '<(PRODUCT_DIR)/<(project_name).bin',
          ],
        },
      ],
    },

    {
      'target_name': 'nocleo_demonstrations.elf',
      'variables': {
        'project_name': 'Demonstrations',
        'project_path':
          '<(nucleo_projects)/<(project_name)',
        'project_include_path': '<(project_path)/Inc/',
        'project_source_path': '<(project_path)/Src/',
        'ldflags': [
          '-specs=nosys.specs',
          '-specs=nano.specs',
          '-T<(project_path)/SW4STM32/STM32F4xx_Nucleo/STM32F411RETx_FLASH.ld',
        ],
      },
      'type': 'executable',
      'includes': [
        'stm32f4_hal_sources.gypi',
      ],
      'include_dirs': [
        '<(project_include_path)',
      ],
      'defines': [
        'STM32F411xE',
        'USE_STM32F4XX_NUCLEO',
      ],
      'sources': [
        # Application.
        '<(project_source_path)/main.c',
        '<(project_source_path)/stm32f4xx_hal_msp.c',
        '<(project_source_path)/usbd_conf.c',
        '<(project_source_path)/usbd_desc.c',

        # Board initialization and interrupt service routines.
        '<(project_source_path)/stm32f4xx_it.c',
        '<(project_source_path)/system_stm32f4xx.c',
        '<(project_path)/SW4STM32/startup_stm32f411xe.s',

        # Board support packages.
        '<(stm32_cube_f4_bsp_discovery)/stm32f4_discovery.c',

        '<(stm32_cube_f4)/Drivers/BSP/Components/lis302dl/lis302dl.c',
        '<(stm32_cube_f4)/Drivers/BSP/Components/lis3dsh/lis3dsh.c',
        '<(stm32_cube_f4)/Drivers/BSP/STM32F4-Discovery/stm32f4_discovery_accelerometer.c',

        # XXX
        '<(stm32_cube_f4)/Middlewares/ST/STM32_USB_Device_Library/Core/Src/usbd_core.c',
        '<(stm32_cube_f4)/Middlewares/ST/STM32_USB_Device_Library/Core/Src/usbd_ctlreq.c',
        '<(stm32_cube_f4)/Middlewares/ST/STM32_USB_Device_Library/Core/Src/usbd_ioreq.c',

        '<(stm32_cube_f4)/Middlewares/ST/STM32_USB_Device_Library/Class/HID/Src/usbd_hid.c',
      ],
      'conditions': [
        ['OS=="mac"', {
          'xcode_settings': {
            'OTHER_LDFLAGS': [
              '<@(ldflags)',
            ],
          },
        }],
        ['OS=="linux"', {
          'ldflags': [
            '<@(ldflags)',
          ],
        }],
      ],
    },
    {
      'variables': {
        'project_name': 'Demonstrations',
      },
      'type': 'none',
      'target_name': 'Demonstrations',
      'dependencies' : [
        'Demonstrations.elf'
      ],
      'actions': [
        {
          'action_name': 'generate_bin',
          'inputs': [
            '<(PRODUCT_DIR)/<(project_name).elf',
          ],
          'outputs': [
            '<(PRODUCT_DIR)/<(project_name).bin',
          ],
          'action': [
            '<(objcopy)',
            '-O',
            'binary',
            '<(PRODUCT_DIR)/<(project_name).elf',
            '<(PRODUCT_DIR)/<(project_name).bin',
          ],
        },
      ],
    },
  ],
}
