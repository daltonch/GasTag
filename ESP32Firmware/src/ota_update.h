/*
 * OTA Update Module for GasTag Bridge
 *
 * Provides WiFi SoftAP mode and HTTP server for firmware updates.
 * When OTA mode is activated via BLE command, the device:
 * 1. Stops BLE advertising
 * 2. Starts WiFi SoftAP (SSID: "GasTag-Update")
 * 3. Runs HTTP server accepting firmware uploads at POST /update
 * 4. Validates and writes firmware to OTA partition
 * 5. Reboots to new firmware on success
 */

#ifndef OTA_UPDATE_H
#define OTA_UPDATE_H

#include "esp_err.h"

// ============== OTA STATE ==============
typedef enum {
    OTA_STATE_IDLE,           // Normal operation, OTA not active
    OTA_STATE_WIFI_STARTING,  // WiFi SoftAP initializing
    OTA_STATE_WIFI_READY,     // WiFi AP ready, waiting for connection
    OTA_STATE_UPDATING,       // Receiving firmware data
    OTA_STATE_VALIDATING,     // Validating firmware checksum
    OTA_STATE_SUCCESS,        // Update successful, about to reboot
    OTA_STATE_FAILED          // Update failed
} ota_state_t;

// ============== OTA CONFIGURATION ==============
#define OTA_WIFI_SSID       "GasTag-Update"
#define OTA_WIFI_PASSWORD   "gastag123"
#define OTA_WIFI_CHANNEL    1
#define OTA_WIFI_MAX_CONN   1
#define OTA_HTTP_PORT       80
#define OTA_CHUNK_SIZE      4096
#define OTA_TIMEOUT_MS      300000  // 5 minutes total timeout

// ============== OTA ERROR CODES ==============
#define OTA_ERR_WIFI_INIT       0x1001
#define OTA_ERR_WIFI_START      0x1002
#define OTA_ERR_HTTP_INIT       0x1003
#define OTA_ERR_OTA_BEGIN       0x1004
#define OTA_ERR_OTA_WRITE       0x1005
#define OTA_ERR_OTA_END         0x1006
#define OTA_ERR_VALIDATION      0x1007
#define OTA_ERR_SET_BOOT        0x1008
#define OTA_ERR_TIMEOUT         0x1009

// ============== PUBLIC API ==============

/**
 * Initialize the OTA update module.
 * Must be called once at startup before using other OTA functions.
 *
 * @return ESP_OK on success, error code on failure
 */
esp_err_t ota_init(void);

/**
 * Start OTA update mode.
 * Stops BLE, starts WiFi SoftAP, and runs HTTP server.
 * This function blocks until update completes or times out.
 *
 * @return ESP_OK on success (device will reboot), error code on failure
 */
esp_err_t ota_start_update_mode(void);

/**
 * Stop OTA update mode and return to normal operation.
 * Stops HTTP server and WiFi, restarts BLE.
 */
void ota_stop_update_mode(void);

/**
 * Get current OTA state.
 *
 * @return Current OTA state
 */
ota_state_t ota_get_state(void);

/**
 * Get OTA update progress (0-100).
 *
 * @return Progress percentage, or -1 if not updating
 */
int ota_get_progress(void);

/**
 * Get last error code from OTA update.
 *
 * @return Error code, or 0 if no error
 */
uint32_t ota_get_last_error(void);

#endif // OTA_UPDATE_H
