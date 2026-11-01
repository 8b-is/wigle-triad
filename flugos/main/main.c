/* ============================================================================
 * FlugOS Unified Entrypoint: main/main.c
 * ============================================================================
 * Dispatches to Node 1 (EAR), Node 2 (BRAIN), or Node 3 (MOUTH) based on
 * `FLUGOS_NODE_ROLE` / `CONFIG_FLUGOS_NODE_ROLE`.
 * ============================================================================ */

#include "flugos_mesh.h"

#ifdef ESP_PLATFORM
#include "esp_log.h"
static const char *TAG = "FLUGOS_MAIN";
#endif

void app_main(void) {
    const uint8_t role = (uint8_t)FLUGOS_NODE_ROLE;
    flugos_mesh_init(role, 6U, true);

#ifdef ESP_PLATFORM
    ESP_LOGI(TAG, "Booting FlugOS 3-Node Offline Voice Mesh (FLUGOS_NODE_ROLE=%u)", (unsigned)role);
#endif

    if (role == FLUGOS_NODE_ROLE_EAR) {
        flugos_node_ear_main();
    } else if (role == FLUGOS_NODE_ROLE_BRAIN) {
        flugos_node_brain_main();
    } else if (role == FLUGOS_NODE_ROLE_MOUTH) {
        flugos_node_mouth_main();
    }
}
