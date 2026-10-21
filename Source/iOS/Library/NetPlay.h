// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

typedef struct DOLNetPlayCallbacks
{
  void* context;
  void (*on_event)(void* context, int event, const char* message);
  void (*on_boot_game)(void* context, const char* path, void* boot_session_data);
} DOLNetPlayCallbacks;

typedef void (*DOLNetPlaySessionCallback)(void* context, const char* name, const char* region,
                                          const char* method, const char* server_id,
                                          const char* game, const char* version, int player_count,
                                          int port, bool has_password, bool in_game);

typedef struct DOLNetPlayPlayerInfo
{
  uint8_t id;
  bool is_host;
  char name[128];
} DOLNetPlayPlayerInfo;

// Mirrors NetPlay::SyncIdentifierComparison. Ordered from best to worst.
typedef enum DOLNetPlayGameComparison
{
  DOLNetPlayGameComparisonSameGame = 0,
  DOLNetPlayGameComparisonDifferentHash = 1,
  DOLNetPlayGameComparisonDifferentDiscNumber = 2,
  DOLNetPlayGameComparisonDifferentRevision = 3,
  DOLNetPlayGameComparisonDifferentRegion = 4,
  DOLNetPlayGameComparisonDifferentGame = 5,
  DOLNetPlayGameComparisonUnknown = 6,
} DOLNetPlayGameComparison;

enum
{
  DOLNetPlayEventPlayers = 0,
  DOLNetPlayEventChat = 1,
  DOLNetPlayEventGame = 2,
  DOLNetPlayEventStatus = 3,
  DOLNetPlayEventError = 4,
  DOLNetPlayEventIndex = 5,
  DOLNetPlayEventStartGame = 6,
  DOLNetPlayEventPowerButton = 7,
  DOLNetPlayEventConnectionLost = 8,
  DOLNetPlayEventTraversalRetryableError = 9,
  DOLNetPlayEventTraversalFatalError = 10,
  DOLNetPlayEventTraversalConnected = 11
};

typedef const void* DOLGameFileHandle;

__attribute__((visibility("default"))) void* DOLNetPlayCreate(
    const char* const* game_paths, size_t game_count, const DOLNetPlayCallbacks* callbacks);
__attribute__((visibility("default"))) void* DOLNetPlayCreateWithGames(
    const DOLGameFileHandle* game_file_ptrs, size_t game_count,
    const DOLNetPlayCallbacks* callbacks);
__attribute__((visibility("default"))) bool DOLNetPlayConnect(
    void* session, bool host, bool traversal, const char* address_or_code, uint16_t port,
    const char* nickname, const char* traversal_server, uint16_t traversal_port,
    uint16_t traversal_port_alt, bool use_upnp);
__attribute__((visibility("default"))) void DOLNetPlayClose(void* session);
__attribute__((visibility("default"))) uint16_t DOLNetPlayGetPort(void* session);
__attribute__((visibility("default"))) bool DOLNetPlayGetExternalIP(char* output,
                                                                     size_t output_size);
__attribute__((visibility("default"))) bool DOLNetPlayGetLocalIP(char* output, size_t output_size);
__attribute__((visibility("default"))) bool DOLNetPlaySetGame(void* session, const char* path);
__attribute__((visibility("default"))) bool DOLNetPlayHasGameSelected(void* session);
__attribute__((visibility("default"))) bool DOLNetPlayIsSelectedGameAvailable(void* session);
__attribute__((visibility("default"))) int DOLNetPlayGetSelectedGameComparison(void* session);
__attribute__((visibility("default"))) bool DOLNetPlayGetSelectedGameTitle(void* session,
                                                                          char* output,
                                                                          size_t output_size);
__attribute__((visibility("default"))) bool DOLNetPlayDoAllPlayersHaveGame(void* session);
__attribute__((visibility("default"))) void DOLNetPlayStartGame(void* session);
__attribute__((visibility("default"))) void DOLNetPlayStartClientGame(void* session);
__attribute__((visibility("default"))) void DOLNetPlayTriggerPowerButton(void* session);
__attribute__((visibility("default"))) void DOLNetPlaySendChat(void* session, const char* message);
__attribute__((visibility("default"))) size_t DOLNetPlayGetPlayers(
    void* session, DOLNetPlayPlayerInfo* output, size_t output_count);
__attribute__((visibility("default"))) bool DOLNetPlayGetControllerMappings(
    void* session, uint8_t* gamecube_ports, size_t gamecube_count, uint8_t* wii_remotes,
    size_t wiimote_count);
__attribute__((visibility("default"))) bool DOLNetPlaySetControllerMapping(
    void* session, bool wiimote, int port, uint8_t player_id);
__attribute__((visibility("default"))) void DOLNetPlaySetHostInputAuthority(void* session,
                                                                             bool enabled);
__attribute__((visibility("default"))) void DOLNetPlayAdjustPadBuffer(void* session, int buffer,
                                                                      bool client_buffer);
__attribute__((visibility("default"))) bool DOLNetPlayBrowse(
    DOLNetPlaySessionCallback callback, void* context);
__attribute__((visibility("default"))) bool DOLNetPlayDecryptSessionId(
    const char* server_id, const char* password, char* output, size_t output_size);
__attribute__((visibility("default"))) bool DOLNetPlayRetryTraversal(void* session);

#if defined(__cplusplus)
}
#endif
