/*
 * OTA Update Module Implementation
 *
 * Implements WiFi SoftAP and HTTP server for OTA firmware updates.
 */

#include "ota_update.h"

#include <string.h>
#include <sys/param.h>  // For MIN macro
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "esp_log.h"
#include "esp_mac.h"    // For MACSTR and MAC2STR
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_http_server.h"
#include "esp_ota_ops.h"
#include "esp_app_format.h"
#include "nvs_flash.h"

static const char *TAG = "OTA";

// ============== STATE ==============
static ota_state_t current_state = OTA_STATE_IDLE;
static int update_progress = -1;
static uint32_t last_error = 0;
static httpd_handle_t http_server = NULL;
static esp_netif_t *ap_netif = NULL;
static bool wifi_initialized = false;

// OTA handle for writing firmware
static esp_ota_handle_t ota_handle = 0;
static const esp_partition_t *update_partition = NULL;
static size_t total_size = 0;
static size_t received_size = 0;

// ============== WIFI EVENT HANDLER ==============
static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data) {
    if (event_base == WIFI_EVENT) {
        switch (event_id) {
            case WIFI_EVENT_AP_STACONNECTED: {
                wifi_event_ap_staconnected_t *event = (wifi_event_ap_staconnected_t *)event_data;
                ESP_LOGI(TAG, "Station connected: " MACSTR, MAC2STR(event->mac));
                break;
            }
            case WIFI_EVENT_AP_STADISCONNECTED: {
                wifi_event_ap_stadisconnected_t *event = (wifi_event_ap_stadisconnected_t *)event_data;
                ESP_LOGI(TAG, "Station disconnected: " MACSTR, MAC2STR(event->mac));
                break;
            }
            default:
                break;
        }
    }
}

// ============== HTTP HANDLERS ==============

// GET / - Simple status page
static esp_err_t root_get_handler(httpd_req_t *req) {
    const char *html =
        "<!DOCTYPE html><html><head><title>GasTag OTA Update</title></head>"
        "<body><h1>GasTag Firmware Update</h1>"
        "<p>POST firmware binary to /update</p>"
        "<p>Current state: %s</p>"
        "</body></html>";

    const char *state_str = "Unknown";
    switch (current_state) {
        case OTA_STATE_IDLE: state_str = "Idle"; break;
        case OTA_STATE_WIFI_STARTING: state_str = "WiFi Starting"; break;
        case OTA_STATE_WIFI_READY: state_str = "Ready for Update"; break;
        case OTA_STATE_UPDATING: state_str = "Updating"; break;
        case OTA_STATE_VALIDATING: state_str = "Validating"; break;
        case OTA_STATE_SUCCESS: state_str = "Success"; break;
        case OTA_STATE_FAILED: state_str = "Failed"; break;
    }

    char response[512];
    snprintf(response, sizeof(response), html, state_str);
    httpd_resp_set_type(req, "text/html");
    httpd_resp_send(req, response, strlen(response));
    return ESP_OK;
}

// POST /update - Receive and flash firmware
static esp_err_t update_post_handler(httpd_req_t *req) {
    ESP_LOGI(TAG, "OTA update request received, content length: %d", req->content_len);

    if (req->content_len == 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "No firmware data");
        return ESP_FAIL;
    }

    current_state = OTA_STATE_UPDATING;
    total_size = req->content_len;
    received_size = 0;
    update_progress = 0;

    // Find the next OTA partition to write to
    update_partition = esp_ota_get_next_update_partition(NULL);
    if (update_partition == NULL) {
        ESP_LOGE(TAG, "No OTA partition found");
        last_error = OTA_ERR_OTA_BEGIN;
        current_state = OTA_STATE_FAILED;
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "No OTA partition");
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "Writing to partition: %s at offset 0x%lx",
             update_partition->label, update_partition->address);

    // Begin OTA update
    esp_err_t err = esp_ota_begin(update_partition, OTA_WITH_SEQUENTIAL_WRITES, &ota_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_begin failed: %s", esp_err_to_name(err));
        last_error = OTA_ERR_OTA_BEGIN;
        current_state = OTA_STATE_FAILED;
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "OTA begin failed");
        return ESP_FAIL;
    }

    // Allocate buffer for receiving data
    char *buf = malloc(OTA_CHUNK_SIZE);
    if (buf == NULL) {
        ESP_LOGE(TAG, "Failed to allocate receive buffer");
        esp_ota_abort(ota_handle);
        last_error = OTA_ERR_OTA_WRITE;
        current_state = OTA_STATE_FAILED;
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Memory allocation failed");
        return ESP_FAIL;
    }

    // Receive and write firmware in chunks
    int remaining = req->content_len;
    bool first_chunk = true;

    while (remaining > 0) {
        int recv_len = httpd_req_recv(req, buf, MIN(remaining, OTA_CHUNK_SIZE));

        if (recv_len <= 0) {
            if (recv_len == HTTPD_SOCK_ERR_TIMEOUT) {
                // Retry on timeout
                continue;
            }
            ESP_LOGE(TAG, "Error receiving data: %d", recv_len);
            free(buf);
            esp_ota_abort(ota_handle);
            last_error = OTA_ERR_OTA_WRITE;
            current_state = OTA_STATE_FAILED;
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Receive error");
            return ESP_FAIL;
        }

        // Validate first chunk contains valid firmware header
        if (first_chunk) {
            first_chunk = false;
            if (recv_len < sizeof(esp_image_header_t)) {
                ESP_LOGE(TAG, "First chunk too small for header");
                free(buf);
                esp_ota_abort(ota_handle);
                last_error = OTA_ERR_VALIDATION;
                current_state = OTA_STATE_FAILED;
                httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid firmware");
                return ESP_FAIL;
            }

            esp_image_header_t *header = (esp_image_header_t *)buf;
            if (header->magic != ESP_IMAGE_HEADER_MAGIC) {
                ESP_LOGE(TAG, "Invalid firmware magic: 0x%02X (expected 0x%02X)",
                         header->magic, ESP_IMAGE_HEADER_MAGIC);
                free(buf);
                esp_ota_abort(ota_handle);
                last_error = OTA_ERR_VALIDATION;
                current_state = OTA_STATE_FAILED;
                httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid firmware header");
                return ESP_FAIL;
            }
            ESP_LOGI(TAG, "Firmware header validated");
        }

        // Write chunk to OTA partition
        err = esp_ota_write(ota_handle, buf, recv_len);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "esp_ota_write failed: %s", esp_err_to_name(err));
            free(buf);
            esp_ota_abort(ota_handle);
            last_error = OTA_ERR_OTA_WRITE;
            current_state = OTA_STATE_FAILED;
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Write error");
            return ESP_FAIL;
        }

        received_size += recv_len;
        remaining -= recv_len;
        update_progress = (received_size * 100) / total_size;

        if (received_size % (OTA_CHUNK_SIZE * 10) == 0 || remaining == 0) {
            ESP_LOGI(TAG, "Progress: %d%% (%d/%d bytes)",
                     update_progress, received_size, total_size);
        }
    }

    free(buf);

    // Validate and finalize OTA update
    current_state = OTA_STATE_VALIDATING;
    ESP_LOGI(TAG, "Validating firmware...");

    err = esp_ota_end(ota_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_end failed: %s", esp_err_to_name(err));
        last_error = OTA_ERR_OTA_END;
        current_state = OTA_STATE_FAILED;

        if (err == ESP_ERR_OTA_VALIDATE_FAILED) {
            httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Firmware validation failed");
        } else {
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "OTA finalize failed");
        }
        return ESP_FAIL;
    }

    // Set the new partition as boot partition
    err = esp_ota_set_boot_partition(update_partition);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_set_boot_partition failed: %s", esp_err_to_name(err));
        last_error = OTA_ERR_SET_BOOT;
        current_state = OTA_STATE_FAILED;
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Set boot partition failed");
        return ESP_FAIL;
    }

    current_state = OTA_STATE_SUCCESS;
    update_progress = 100;
    ESP_LOGI(TAG, "OTA update successful! Rebooting in 2 seconds...");

    // Send success response
    const char *response = "{\"status\":\"success\",\"message\":\"Update complete, rebooting...\"}";
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, response, strlen(response));

    // Schedule reboot
    vTaskDelay(pdMS_TO_TICKS(2000));
    esp_restart();

    return ESP_OK;  // Won't reach here due to restart
}

// ============== HTTP SERVER ==============
static esp_err_t start_http_server(void) {
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port = OTA_HTTP_PORT;
    config.stack_size = 8192;

    ESP_LOGI(TAG, "Starting HTTP server on port %d", config.server_port);

    esp_err_t err = httpd_start(&http_server, &config);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to start HTTP server: %s", esp_err_to_name(err));
        return err;
    }

    // Register URI handlers
    httpd_uri_t root_uri = {
        .uri = "/",
        .method = HTTP_GET,
        .handler = root_get_handler,
        .user_ctx = NULL
    };
    httpd_register_uri_handler(http_server, &root_uri);

    httpd_uri_t update_uri = {
        .uri = "/update",
        .method = HTTP_POST,
        .handler = update_post_handler,
        .user_ctx = NULL
    };
    httpd_register_uri_handler(http_server, &update_uri);

    ESP_LOGI(TAG, "HTTP server started");
    return ESP_OK;
}

static void stop_http_server(void) {
    if (http_server != NULL) {
        httpd_stop(http_server);
        http_server = NULL;
        ESP_LOGI(TAG, "HTTP server stopped");
    }
}

// ============== WIFI SOFTAP ==============
static esp_err_t start_wifi_ap(void) {
    current_state = OTA_STATE_WIFI_STARTING;

    // Initialize TCP/IP stack (only once)
    if (!wifi_initialized) {
        ESP_LOGI(TAG, "Initializing network stack for OTA...");

        // esp_netif_init may already be called - it's safe to call multiple times
        esp_err_t ret = esp_netif_init();
        if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
            ESP_LOGE(TAG, "esp_netif_init failed: %s", esp_err_to_name(ret));
            return ret;
        }

        // Event loop may already exist (created by USB host or BLE stack)
        ret = esp_event_loop_create_default();
        if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
            ESP_LOGE(TAG, "esp_event_loop_create_default failed: %s", esp_err_to_name(ret));
            return ret;
        }

        wifi_initialized = true;
        ESP_LOGI(TAG, "Network stack initialized");
    }

    // Create AP network interface
    if (ap_netif == NULL) {
        ap_netif = esp_netif_create_default_wifi_ap();
    }

    // Initialize WiFi
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_err_t err = esp_wifi_init(&cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "WiFi init failed: %s", esp_err_to_name(err));
        last_error = OTA_ERR_WIFI_INIT;
        current_state = OTA_STATE_FAILED;
        return err;
    }

    // Register event handler
    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT,
                    ESP_EVENT_ANY_ID, &wifi_event_handler, NULL, NULL));

    // Configure SoftAP
    // Use WPA_WPA2_PSK for better iOS compatibility with programmatic WiFi joining
    wifi_config_t wifi_config = {
        .ap = {
            .ssid = OTA_WIFI_SSID,
            .ssid_len = strlen(OTA_WIFI_SSID),
            .channel = 6,  // Channel 6 is often more compatible
            .password = OTA_WIFI_PASSWORD,
            .max_connection = 4,  // Allow more connections for reliability
            .authmode = WIFI_AUTH_WPA_WPA2_PSK,  // More compatible than WPA2 only
            .pmf_cfg = {
                .required = false,
                .capable = false,  // Disable PMF completely for compatibility
            },
        },
    };

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &wifi_config));

    err = esp_wifi_start();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "WiFi start failed: %s", esp_err_to_name(err));
        last_error = OTA_ERR_WIFI_START;
        current_state = OTA_STATE_FAILED;
        return err;
    }

    current_state = OTA_STATE_WIFI_READY;
    ESP_LOGI(TAG, "WiFi SoftAP started - SSID: %s, Password: %s",
             OTA_WIFI_SSID, OTA_WIFI_PASSWORD);
    ESP_LOGI(TAG, "Connect to WiFi and POST firmware to http://192.168.4.1/update");

    return ESP_OK;
}

static void stop_wifi_ap(void) {
    esp_wifi_stop();
    esp_wifi_deinit();
    ESP_LOGI(TAG, "WiFi stopped");
}

// ============== PUBLIC API ==============

esp_err_t ota_init(void) {
    current_state = OTA_STATE_IDLE;
    update_progress = -1;
    last_error = 0;
    ESP_LOGI(TAG, "OTA module initialized");
    return ESP_OK;
}

esp_err_t ota_start_update_mode(void) {
    ESP_LOGI(TAG, "Starting OTA update mode...");

    // Start WiFi AP
    esp_err_t err = start_wifi_ap();
    if (err != ESP_OK) {
        return err;
    }

    // Start HTTP server
    err = start_http_server();
    if (err != ESP_OK) {
        stop_wifi_ap();
        last_error = OTA_ERR_HTTP_INIT;
        current_state = OTA_STATE_FAILED;
        return err;
    }

    ESP_LOGI(TAG, "OTA update mode active");
    return ESP_OK;
}

void ota_stop_update_mode(void) {
    ESP_LOGI(TAG, "Stopping OTA update mode...");
    stop_http_server();
    stop_wifi_ap();
    current_state = OTA_STATE_IDLE;
    update_progress = -1;
}

ota_state_t ota_get_state(void) {
    return current_state;
}

int ota_get_progress(void) {
    return update_progress;
}

uint32_t ota_get_last_error(void) {
    return last_error;
}
