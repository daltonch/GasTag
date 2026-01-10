/*
 * GasTag Bridge - ESP32-S3 USB Host to BLE Bridge
 *
 * Reads data from a USB CDC serial device (gas analyzer) and
 * broadcasts it over Bluetooth Low Energy (BLE).
 *
 * Hardware: ESP32-S3-DevKitC-1
 * Wiring:
 *   USB Cable White -> GPIO 19 (D-)
 *   USB Cable Green -> GPIO 20 (D+)
 *   USB Cable Black -> GND
 *   USB Cable Red   -> NOT CONNECTED (powered by iPhone USB-C)
 */

#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_log.h"
#include "esp_err.h"
#include "nvs_flash.h"

// BLE includes
#include "esp_bt.h"
#include "esp_gap_ble_api.h"
#include "esp_gatts_api.h"
#include "esp_bt_main.h"
#include "esp_gatt_common_api.h"

// USB Host includes
#include "usb/usb_host.h"
#include "usb/cdc_acm_host.h"

// OTA Update includes
#include "ota_update.h"

static const char *TAG = "GasTag";

// ============== FIRMWARE VERSION ==============
#define FIRMWARE_VERSION "1.0.3"

// ============== USB DEVICE DETECTION ==============
// No longer restricted to specific VID/PID - accepts any USB CDC device
static volatile uint16_t detected_vid = 0;
static volatile uint16_t detected_pid = 0;
static volatile bool device_available = false;

// ============== BLE CONFIGURATION ==============
#define DEVICE_NAME "GasTag Bridge"
#define GATTS_NUM_HANDLE     10  // Increased for version and OTA characteristics

// Full 128-bit UUIDs for iOS compatibility (little-endian byte order)
// Service UUID: A1B2C3D4-E5F6-7890-ABCD-EF1234567890
static uint8_t service_uuid128[16] = {
    0x90, 0x78, 0x56, 0x34, 0x12, 0xEF, 0xCD, 0xAB,
    0x90, 0x78, 0xF6, 0xE5, 0xD4, 0xC3, 0xB2, 0xA1
};

// Characteristic UUID: A1B2C3D5-E5F6-7890-ABCD-EF1234567890 (Gas Data)
static uint8_t char_uuid128[16] = {
    0x90, 0x78, 0x56, 0x34, 0x12, 0xEF, 0xCD, 0xAB,
    0x90, 0x78, 0xF6, 0xE5, 0xD5, 0xC3, 0xB2, 0xA1
};

// Version Characteristic UUID: A1B2C3D6-E5F6-7890-ABCD-EF1234567890 (READ)
static uint8_t version_char_uuid128[16] = {
    0x90, 0x78, 0x56, 0x34, 0x12, 0xEF, 0xCD, 0xAB,
    0x90, 0x78, 0xF6, 0xE5, 0xD6, 0xC3, 0xB2, 0xA1
};

// OTA Control Characteristic UUID: A1B2C3D7-E5F6-7890-ABCD-EF1234567890 (WRITE)
static uint8_t ota_char_uuid128[16] = {
    0x90, 0x78, 0x56, 0x34, 0x12, 0xEF, 0xCD, 0xAB,
    0x90, 0x78, 0xF6, 0xE5, 0xD7, 0xC3, 0xB2, 0xA1
};

// ============== GLOBALS ==============
static uint16_t gatts_if = ESP_GATT_IF_NONE;
static uint16_t conn_id = 0;
static bool device_connected = false;
static uint16_t char_handle = 0;
static uint16_t version_char_handle = 0;
static uint16_t ota_char_handle = 0;
static uint16_t service_handle = 0;

// OTA mode flag - set when BLE client writes 0x01 to OTA characteristic
static volatile bool ota_mode_requested = false;

static char last_reading[256] = "";
static char line_buffer[256] = "";
static int line_buffer_pos = 0;

static SemaphoreHandle_t device_disconnected_sem;

// Watchdog: track last data time to detect stale connections
static volatile uint32_t last_data_time_ms = 0;
#define DATA_TIMEOUT_MS 5000  // 5 seconds without data = assume disconnected

// ============== BLE ADVERTISING ==============
static esp_ble_adv_params_t adv_params = {
    .adv_int_min = 0x20,
    .adv_int_max = 0x40,
    .adv_type = ADV_TYPE_IND,
    .own_addr_type = BLE_ADDR_TYPE_PUBLIC,
    .channel_map = ADV_CHNL_ALL,
    .adv_filter_policy = ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY,
};

// Advertising data (kept small to fit in 31 bytes)
static esp_ble_adv_data_t adv_data = {
    .set_scan_rsp = false,
    .include_name = true,
    .include_txpower = false,
    .min_interval = 0x0006,
    .max_interval = 0x0010,
    .appearance = 0x00,
    .manufacturer_len = 0,
    .p_manufacturer_data = NULL,
    .service_data_len = 0,
    .p_service_data = NULL,
    .service_uuid_len = 0,
    .p_service_uuid = NULL,
    .flag = (ESP_BLE_ADV_FLAG_GEN_DISC | ESP_BLE_ADV_FLAG_BREDR_NOT_SPT),
};

// Scan response data (contains the service UUID for iOS discovery)
static esp_ble_adv_data_t scan_rsp_data = {
    .set_scan_rsp = true,
    .include_name = false,
    .include_txpower = false,
    .appearance = 0x00,
    .manufacturer_len = 0,
    .p_manufacturer_data = NULL,
    .service_data_len = 0,
    .p_service_data = NULL,
    .service_uuid_len = 16,
    .p_service_uuid = service_uuid128,
    .flag = 0,
};

// ============== BLE CHARACTERISTIC ==============
static esp_attr_value_t char_val = {
    .attr_max_len = 256,
    .attr_len = sizeof("GasTag Bridge Ready") - 1,
    .attr_value = (uint8_t *)"GasTag Bridge Ready",
};

// ============== USB CDC HOST CALLBACKS ==============
static bool handle_rx(const uint8_t *data, size_t data_len, void *arg) {
    // Update watchdog timestamp on any data received
    last_data_time_ms = xTaskGetTickCount() * portTICK_PERIOD_MS;

    for (size_t i = 0; i < data_len; i++) {
        char c = (char)data[i];

        if (c == '\n' || c == '\r') {
            if (line_buffer_pos > 0) {
                line_buffer[line_buffer_pos] = '\0';

                // Copy to last_reading with guaranteed null termination
                strncpy(last_reading, line_buffer, sizeof(last_reading) - 1);
                last_reading[sizeof(last_reading) - 1] = '\0';

                // Send via BLE if connected
                if (device_connected && gatts_if != ESP_GATT_IF_NONE && char_handle != 0) {
                    esp_ble_gatts_send_indicate(gatts_if, conn_id, char_handle,
                        line_buffer_pos, (uint8_t *)line_buffer, false);
                }

                ESP_LOGI(TAG, "Data: %s", line_buffer);

                // Clear buffer for next line
                line_buffer_pos = 0;
                line_buffer[0] = '\0';
            }
        } else if (c >= 32 && c < 127) {  // Only printable ASCII
            if (line_buffer_pos < sizeof(line_buffer) - 1) {
                line_buffer[line_buffer_pos++] = c;
            }
        }
        // Ignore non-printable characters
    }
    return true;
}

static void handle_event(const cdc_acm_host_dev_event_data_t *event, void *user_ctx) {
    switch (event->type) {
        case CDC_ACM_HOST_NETWORK_CONNECTION:
        case CDC_ACM_HOST_SERIAL_STATE:
            ESP_LOGI(TAG, "USB CDC device event");
            break;
        case CDC_ACM_HOST_DEVICE_DISCONNECTED:
            ESP_LOGI(TAG, "USB device disconnected");
            xSemaphoreGive(device_disconnected_sem);
            break;
        default:
            break;
    }
}

// ============== USB DEVICE DETECTION CALLBACK ==============
static void new_device_cb(usb_device_handle_t usb_dev) {
    const usb_device_desc_t *desc;
    usb_host_get_device_descriptor(usb_dev, &desc);
    ESP_LOGI(TAG, "*** USB Device detected! VID=0x%04X, PID=0x%04X ***",
             desc->idVendor, desc->idProduct);

    // Store detected device info for the USB task to use
    detected_vid = desc->idVendor;
    detected_pid = desc->idProduct;
    device_available = true;
}

// ============== USB HOST TASK ==============
static void usb_host_task(void *arg) {
    ESP_LOGI(TAG, "Initializing USB Host...");

    // Install USB Host library
    usb_host_config_t host_config = {
        .skip_phy_setup = false,
        .intr_flags = ESP_INTR_FLAG_LEVEL1,
    };
    esp_err_t err = usb_host_install(&host_config);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "USB Host install failed: %s", esp_err_to_name(err));
        vTaskDelete(NULL);
        return;
    }

    // CDC ACM driver configuration - with device detection callback
    cdc_acm_host_driver_config_t driver_config = {
        .driver_task_stack_size = 4096,
        .driver_task_priority = 10,
        .xCoreID = 0,
        .new_dev_cb = new_device_cb,  // Log any new device
    };
    err = cdc_acm_host_install(&driver_config);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "CDC ACM Host install failed: %s", esp_err_to_name(err));
        vTaskDelete(NULL);
        return;
    }
    ESP_LOGI(TAG, "CDC ACM driver installed - waiting for USB devices...");

    device_disconnected_sem = xSemaphoreCreateBinary();

    ESP_LOGI(TAG, "Starting USB host event processing...");

    // Brief wait for USB device enumeration - process events without blocking too long
    ESP_LOGI(TAG, "Waiting for USB device enumeration...");
    for (int i = 0; i < 20; i++) {  // 2 seconds max (20 * 100ms)
        uint32_t event_flags = 0;
        usb_host_lib_handle_events(100, &event_flags);
    }

    while (true) {
        // Handle USB host library events
        uint32_t event_flags = 0;
        usb_host_lib_handle_events(100, &event_flags);

        // Check if a device was detected by the callback
        if (!device_available) {
            vTaskDelay(pdMS_TO_TICKS(100));
            continue;
        }

        // Capture the detected VID/PID (volatile, so copy locally)
        uint16_t vid = detected_vid;
        uint16_t pid = detected_pid;
        device_available = false;  // Reset flag

        ESP_LOGI(TAG, "Attempting to open USB device VID=0x%04X PID=0x%04X", vid, pid);

        // CDC device configuration - shorter timeout for faster retries
        cdc_acm_host_device_config_t dev_config = {
            .connection_timeout_ms = 1000,  // 1 second timeout
            .out_buffer_size = 512,
            .in_buffer_size = 512,
            .event_cb = handle_event,
            .data_cb = handle_rx,
            .user_arg = NULL,
        };

        cdc_acm_dev_hdl_t cdc_dev = NULL;

        // Try to open the detected device
        esp_err_t err = cdc_acm_host_open(vid, pid, 0, &dev_config, &cdc_dev);

        if (err == ESP_OK && cdc_dev != NULL) {
            ESP_LOGI(TAG, "USB CDC device connected (VID=0x%04X PID=0x%04X)!", vid, pid);

            // Set line coding: 115200 8N1
            cdc_acm_line_coding_t line_coding = {
                .dwDTERate = 115200,
                .bCharFormat = 0,  // 1 stop bit
                .bParityType = 0,  // No parity
                .bDataBits = 8,
            };
            cdc_acm_host_line_coding_set(cdc_dev, &line_coding);

            // Enable DTR
            cdc_acm_host_set_control_line_state(cdc_dev, true, false);

            // Initialize watchdog timestamp
            last_data_time_ms = xTaskGetTickCount() * portTICK_PERIOD_MS;

            // Wait for disconnection - use timeout to allow watchdog checking
            bool device_active = true;
            while (device_active) {
                // Check for explicit disconnect event (1 second timeout)
                if (xSemaphoreTake(device_disconnected_sem, pdMS_TO_TICKS(1000)) == pdTRUE) {
                    ESP_LOGI(TAG, "USB disconnect event received");
                    device_active = false;
                } else {
                    // No disconnect event - check data watchdog
                    uint32_t now_ms = xTaskGetTickCount() * portTICK_PERIOD_MS;
                    uint32_t elapsed = now_ms - last_data_time_ms;

                    if (elapsed > DATA_TIMEOUT_MS) {
                        ESP_LOGW(TAG, "No data for %lu ms - assuming device disconnected", elapsed);
                        device_active = false;
                    }
                }
            }

            // Close device and prepare for reconnection
            ESP_LOGI(TAG, "Closing USB device...");
            cdc_acm_host_close(cdc_dev);
            cdc_dev = NULL;

            // Allow USB stack to settle before accepting new device
            vTaskDelay(pdMS_TO_TICKS(500));
        } else {
            ESP_LOGW(TAG, "Failed to open USB device (may not be CDC-compatible): %s", esp_err_to_name(err));
        }
        // Loop will wait for next device_available signal
    }
}

// ============== BLE GAP EVENT HANDLER ==============
static bool adv_config_done = false;
static bool scan_rsp_config_done = false;

static void gap_event_handler(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param) {
    switch (event) {
        case ESP_GAP_BLE_ADV_DATA_SET_COMPLETE_EVT:
            adv_config_done = true;
            if (scan_rsp_config_done) {
                esp_ble_gap_start_advertising(&adv_params);
            }
            break;
        case ESP_GAP_BLE_SCAN_RSP_DATA_SET_COMPLETE_EVT:
            scan_rsp_config_done = true;
            if (adv_config_done) {
                esp_ble_gap_start_advertising(&adv_params);
            }
            break;
        case ESP_GAP_BLE_ADV_START_COMPLETE_EVT:
            if (param->adv_start_cmpl.status == ESP_BT_STATUS_SUCCESS) {
                ESP_LOGI(TAG, "BLE advertising started");
            } else {
                ESP_LOGE(TAG, "BLE advertising failed to start");
            }
            break;
        default:
            break;
    }
}

// ============== BLE GATTS EVENT HANDLER ==============
static void gatts_event_handler(esp_gatts_cb_event_t event, esp_gatt_if_t gatt_if,
                                 esp_ble_gatts_cb_param_t *param) {
    switch (event) {
        case ESP_GATTS_REG_EVT:
            gatts_if = gatt_if;
            esp_ble_gap_set_device_name(DEVICE_NAME);
            esp_ble_gap_config_adv_data(&adv_data);
            esp_ble_gap_config_adv_data(&scan_rsp_data);

            // Create service
            esp_gatt_srvc_id_t service_id = {
                .is_primary = true,
                .id = {
                    .inst_id = 0,
                    .uuid = {
                        .len = ESP_UUID_LEN_128,
                    },
                },
            };
            memcpy(service_id.id.uuid.uuid.uuid128, service_uuid128, 16);
            esp_ble_gatts_create_service(gatt_if, &service_id, GATTS_NUM_HANDLE);
            break;

        case ESP_GATTS_CREATE_EVT:
            service_handle = param->create.service_handle;
            esp_ble_gatts_start_service(service_handle);

            // Add gas data characteristic (READ + NOTIFY)
            esp_bt_uuid_t gas_char_uuid = {
                .len = ESP_UUID_LEN_128,
            };
            memcpy(gas_char_uuid.uuid.uuid128, char_uuid128, 16);
            esp_ble_gatts_add_char(service_handle, &gas_char_uuid,
                ESP_GATT_PERM_READ,
                ESP_GATT_CHAR_PROP_BIT_READ | ESP_GATT_CHAR_PROP_BIT_NOTIFY,
                &char_val, NULL);
            break;

        case ESP_GATTS_ADD_CHAR_EVT: {
            // Determine which characteristic was just added based on UUID
            uint8_t *added_uuid = param->add_char.char_uuid.uuid.uuid128;

            if (memcmp(added_uuid, char_uuid128, 16) == 0) {
                // Gas data characteristic added - store handle and add CCCD
                char_handle = param->add_char.attr_handle;
                ESP_LOGI(TAG, "Gas data characteristic added, handle=%d", char_handle);

                // Add CCCD descriptor for notifications
                esp_bt_uuid_t descr_uuid = {
                    .len = ESP_UUID_LEN_16,
                    .uuid = { .uuid16 = ESP_GATT_UUID_CHAR_CLIENT_CONFIG },
                };
                esp_ble_gatts_add_char_descr(service_handle, &descr_uuid,
                    ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE, NULL, NULL);
            } else if (memcmp(added_uuid, version_char_uuid128, 16) == 0) {
                // Version characteristic added
                version_char_handle = param->add_char.attr_handle;
                ESP_LOGI(TAG, "Version characteristic added, handle=%d", version_char_handle);

                // Add OTA control characteristic (WRITE only)
                esp_bt_uuid_t ota_uuid = {
                    .len = ESP_UUID_LEN_128,
                };
                memcpy(ota_uuid.uuid.uuid128, ota_char_uuid128, 16);
                esp_ble_gatts_add_char(service_handle, &ota_uuid,
                    ESP_GATT_PERM_WRITE,
                    ESP_GATT_CHAR_PROP_BIT_WRITE,
                    NULL, NULL);
            } else if (memcmp(added_uuid, ota_char_uuid128, 16) == 0) {
                // OTA control characteristic added
                ota_char_handle = param->add_char.attr_handle;
                ESP_LOGI(TAG, "OTA control characteristic added, handle=%d", ota_char_handle);
                ESP_LOGI(TAG, "All BLE characteristics registered successfully");
            }
            break;
        }

        case ESP_GATTS_ADD_CHAR_DESCR_EVT:
            // CCCD descriptor added - now add version characteristic
            ESP_LOGI(TAG, "CCCD descriptor added, adding version characteristic");
            esp_bt_uuid_t ver_uuid = {
                .len = ESP_UUID_LEN_128,
            };
            memcpy(ver_uuid.uuid.uuid128, version_char_uuid128, 16);
            esp_ble_gatts_add_char(service_handle, &ver_uuid,
                ESP_GATT_PERM_READ,
                ESP_GATT_CHAR_PROP_BIT_READ,
                NULL, NULL);
            break;

        case ESP_GATTS_CONNECT_EVT:
            conn_id = param->connect.conn_id;
            device_connected = true;
            ESP_LOGI(TAG, "BLE Client connected");

            // Request connection parameter update for iOS compatibility
            esp_ble_conn_update_params_t conn_params = {0};
            memcpy(conn_params.bda, param->connect.remote_bda, sizeof(esp_bd_addr_t));
            conn_params.min_int = 0x10;  // 20ms (0x10 * 1.25ms)
            conn_params.max_int = 0x20;  // 40ms (0x20 * 1.25ms)
            conn_params.latency = 0;
            conn_params.timeout = 400;   // 4000ms (400 * 10ms)
            esp_ble_gap_update_conn_params(&conn_params);
            // Don't send data here - wait for MTU negotiation and notification subscription
            break;

        case ESP_GATTS_MTU_EVT:
            ESP_LOGI(TAG, "MTU negotiated: %d", param->mtu.mtu);
            break;

        case ESP_GATTS_WRITE_EVT:
            ESP_LOGI(TAG, "Write event: handle=%d, len=%d", param->write.handle, param->write.len);

            // Check if this is a write to the OTA control characteristic
            if (param->write.handle == ota_char_handle && param->write.len >= 1) {
                uint8_t command = param->write.value[0];
                ESP_LOGI(TAG, "OTA control command received: 0x%02X", command);

                if (command == 0x01) {
                    // Enter OTA update mode
                    ESP_LOGI(TAG, "OTA mode requested via BLE");
                    ota_mode_requested = true;
                }
            }

            // Send response if needed
            if (param->write.need_rsp) {
                esp_ble_gatts_send_response(gatt_if, param->write.conn_id,
                    param->write.trans_id, ESP_GATT_OK, NULL);
            }
            break;

        case ESP_GATTS_DISCONNECT_EVT:
            device_connected = false;
            ESP_LOGI(TAG, "BLE Client disconnected, restarting advertising");
            esp_ble_gap_start_advertising(&adv_params);
            break;

        case ESP_GATTS_READ_EVT: {
            // Handle read request
            esp_gatt_rsp_t rsp;
            memset(&rsp, 0, sizeof(esp_gatt_rsp_t));
            rsp.attr_value.handle = param->read.handle;

            if (param->read.handle == version_char_handle) {
                // Return firmware version
                rsp.attr_value.len = strlen(FIRMWARE_VERSION);
                memcpy(rsp.attr_value.value, FIRMWARE_VERSION, rsp.attr_value.len);
                ESP_LOGI(TAG, "Version read: %s", FIRMWARE_VERSION);
            } else if (param->read.handle == char_handle) {
                // Return last gas reading
                rsp.attr_value.len = strlen(last_reading);
                memcpy(rsp.attr_value.value, last_reading, rsp.attr_value.len);
            } else {
                // Unknown handle - return empty
                rsp.attr_value.len = 0;
            }

            esp_ble_gatts_send_response(gatt_if, param->read.conn_id,
                param->read.trans_id, ESP_GATT_OK, &rsp);
            break;
        }

        default:
            break;
    }
}

// ============== BLE SETUP ==============
static void setup_ble(void) {
    esp_err_t ret;

    // Initialize NVS (required for BLE)
    ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    // Release memory for classic BT (we only use BLE)
    ESP_ERROR_CHECK(esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT));

    // Initialize BT controller
    esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_bt_controller_init(&bt_cfg));
    ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_BLE));

    // Initialize Bluedroid
    ESP_ERROR_CHECK(esp_bluedroid_init());
    ESP_ERROR_CHECK(esp_bluedroid_enable());

    // Register callbacks
    ESP_ERROR_CHECK(esp_ble_gatts_register_callback(gatts_event_handler));
    ESP_ERROR_CHECK(esp_ble_gap_register_callback(gap_event_handler));
    ESP_ERROR_CHECK(esp_ble_gatts_app_register(0));

    // Set MTU
    esp_ble_gatt_set_local_mtu(256);

    ESP_LOGI(TAG, "BLE initialized");
}

// ============== MAIN ==============
void app_main(void) {
    ESP_LOGI(TAG, "\n\nGasTag Bridge Starting...");
    ESP_LOGI(TAG, "Firmware version: %s", FIRMWARE_VERSION);

    // Initialize OTA module
    ota_init();

    // Setup BLE
    setup_ble();

    // Start USB Host task on core 1
    xTaskCreatePinnedToCore(usb_host_task, "usb_host", 8192, NULL, 5, NULL, 1);

    ESP_LOGI(TAG, "=== GasTag Bridge Ready ===");

    // Main loop - check for OTA mode request
    while (1) {
        if (ota_mode_requested) {
            // Clear flag immediately to prevent re-entry
            ota_mode_requested = false;

            ESP_LOGI(TAG, "OTA mode requested, stopping BLE and starting WiFi...");

            // Stop BLE advertising before starting WiFi
            esp_ble_gap_stop_advertising();
            esp_bluedroid_disable();
            esp_bluedroid_deinit();
            esp_bt_controller_disable();
            esp_bt_controller_deinit();

            ESP_LOGI(TAG, "BLE stopped, starting OTA update mode...");

            // Start OTA update mode
            esp_err_t err = ota_start_update_mode();
            if (err != ESP_OK) {
                ESP_LOGE(TAG, "OTA update mode failed: %s", esp_err_to_name(err));
                // On failure, restart to restore normal operation
                ESP_LOGI(TAG, "Restarting to restore normal operation...");
                vTaskDelay(pdMS_TO_TICKS(1000));
                esp_restart();
            }

            // OTA mode started successfully - wait for update to complete or timeout
            // The HTTP server handles the actual update. We wait here to prevent
            // the main loop from doing anything else while OTA is active.
            ESP_LOGI(TAG, "Waiting for OTA update (timeout: 5 minutes)...");
            uint32_t ota_start_time = xTaskGetTickCount();
            const uint32_t OTA_TIMEOUT_TICKS = pdMS_TO_TICKS(5 * 60 * 1000);  // 5 minutes

            while (ota_get_state() != OTA_STATE_SUCCESS &&
                   ota_get_state() != OTA_STATE_FAILED) {
                // Check for timeout
                if ((xTaskGetTickCount() - ota_start_time) > OTA_TIMEOUT_TICKS) {
                    ESP_LOGW(TAG, "OTA timeout - no update received");
                    ota_stop_update_mode();
                    ESP_LOGI(TAG, "Restarting to restore normal operation...");
                    vTaskDelay(pdMS_TO_TICKS(1000));
                    esp_restart();
                }
                vTaskDelay(pdMS_TO_TICKS(1000));  // Check every second
            }

            // If we get here with SUCCESS state, device will reboot in the HTTP handler
            // If FAILED, restart to restore normal operation
            if (ota_get_state() == OTA_STATE_FAILED) {
                ESP_LOGE(TAG, "OTA update failed");
                ESP_LOGI(TAG, "Restarting to restore normal operation...");
                vTaskDelay(pdMS_TO_TICKS(1000));
                esp_restart();
            }
        }

        vTaskDelay(pdMS_TO_TICKS(100));  // Check every 100ms
    }
}
