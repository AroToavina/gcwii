// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "NetPlay.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <sys/socket.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "Common/TraversalClient.h"
#include "Common/HttpRequest.h"
#include "Core/Boot/Boot.h"
#include "Core/Config/NetplaySettings.h"
#include "Core/Core.h"
#include "Core/NetPlayClient.h"
#include "Core/NetPlayCommon.h"
#include "Core/NetPlayServer.h"
#include "Core/System.h"
#include "UICommon/GameFile.h"
#include "UICommon/GameFileCache.h"
#include "UICommon/NetPlayIndex.h"
#include "UICommon/UICommon.h"

namespace
{
std::string FromCString(const char* text)
{
  return text ? text : "";
}

class IOSNetPlaySession;

class IOSNetPlayUI final : public NetPlay::NetPlayUI
{
public:
  IOSNetPlayUI(IOSNetPlaySession* session, DOLNetPlayCallbacks callbacks,
               std::vector<std::shared_ptr<const UICommon::GameFile>> games)
      : m_session(session), m_callbacks(callbacks), m_games(std::move(games))
  {
  }

  void SetClient(NetPlay::NetPlayClient* client) { m_client = client; }
  void SetServer(NetPlay::NetPlayServer* server) { m_server = server; }
  void StartSelectedGame();

  void BootGame(const std::string& filename,
                std::unique_ptr<BootSessionData> boot_session_data) override;
  void StopGame() override;
  bool IsHosting() const override { return m_server != nullptr; }
  void Update() override;
  void AppendChat(const std::string& message) override;
  void OnMsgChangeGame(const NetPlay::SyncIdentifier& identifier,
                       const std::string& name) override;
  void OnMsgChangeGBARom(int, const NetPlay::GBAConfig&) override {}
  void OnMsgStartGame() override { Emit(DOLNetPlayEventStartGame, ""); }
  void OnMsgStopGame() override {}
  void OnMsgPowerButton() override { Emit(DOLNetPlayEventPowerButton, ""); }
  void OnPlayerConnect(const std::string&) override { Update(); }
  void OnPlayerDisconnect(const std::string&) override { Update(); }
  void OnPadBufferChanged(u32) override {}
  void OnHostInputAuthorityChanged(bool) override {}
  void OnDesync(u32 frame, const std::string& player) override;
  void OnConnectionLost() override { Emit(DOLNetPlayEventConnectionLost, ""); }
  void OnConnectionError(const std::string& error) override
  {
    Emit(DOLNetPlayEventError, error);
  }
  void OnTraversalError(Common::TraversalClient::FailureReason reason) override;
  void OnTraversalStateChanged(Common::TraversalClient::State state) override;
  void OnGameStartAborted() override { Emit(DOLNetPlayEventError, "Game start was aborted."); }
  void OnGolferChanged(bool, const std::string&) override {}
  void OnTtlDetermined(u8) override {}
  bool IsRecording() override { return false; }
  std::shared_ptr<const UICommon::GameFile>
  FindGameFile(const NetPlay::SyncIdentifier& identifier,
               NetPlay::SyncIdentifierComparison* comparison = nullptr) override;
  std::string FindGBARomPath(const std::array<u8, 20>&, std::string_view, int) override
  {
    return {};
  }
  void ShowGameDigestDialog(const std::string& title) override
  {
    Emit(DOLNetPlayEventStatus, "Checking game data: " + title);
  }
  void SetGameDigestProgress(int pid, int progress) override
  {
    Emit(DOLNetPlayEventStatus, "Checking game data for player " + std::to_string(pid) + ": " +
                                     std::to_string(progress) + "%");
  }
  void SetGameDigestResult(int pid, const std::string& result) override
  {
    Emit(DOLNetPlayEventStatus, "Game data check for player " + std::to_string(pid) + ": " +
                                     result);
  }
  void AbortGameDigest() override { Emit(DOLNetPlayEventStatus, "Game data check canceled."); }
  void OnIndexAdded(bool success, std::string error) override;
  void OnIndexRefreshFailed(std::string error) override;
  void ShowChunkedProgressDialog(const std::string& title, u64 data_size,
                                 const std::vector<int>&) override
  {
    m_transfer_data_size.store(data_size);
    Emit(DOLNetPlayEventStatus, "Synchronizing " + title + " (" +
                                     std::to_string(data_size / (1024 * 1024)) + " MiB)");
  }
  void HideChunkedProgressDialog() override
  {
    m_transfer_data_size.store(0);
    Emit(DOLNetPlayEventStatus, "NetPlay data synchronization complete.");
  }
  void SetChunkedProgress(int pid, u64 progress) override
  {
    const u64 total = m_transfer_data_size.load();
    const u64 percent = total == 0 ? 0 : std::min<u64>(100, (progress * 100) / total);
    Emit(DOLNetPlayEventStatus, "Synchronizing data for player " + std::to_string(pid) + ": " +
                                     std::to_string(percent) + "%");
  }
  void SetHostWiiSyncData(std::vector<u64> titles, std::string redirect_folder) override;

  void Emit(int event, const std::string& message)
  {
    if (m_callbacks.on_event)
      m_callbacks.on_event(m_callbacks.context, event, message.c_str());
  }

  bool HasSelectedGame() const { return !m_current_game.game_id.empty(); }
  bool IsSelectedGameAvailable()
  {
    return HasSelectedGame() && (FindGameFile(m_current_game) != nullptr);
  }
  std::string GetSelectedGameTitle()
  {
    if (const auto game = FindGameFile(m_current_game))
      return game->GetName(UICommon::GameFile::Variant::LongAndPossiblyCustom);
    return {};
  }

private:
  IOSNetPlaySession* m_session;
  DOLNetPlayCallbacks m_callbacks;
  std::vector<std::shared_ptr<const UICommon::GameFile>> m_games;
  NetPlay::NetPlayClient* m_client = nullptr;
  NetPlay::NetPlayServer* m_server = nullptr;
  NetPlay::SyncIdentifier m_current_game{};
  std::chrono::steady_clock::time_point m_last_players_update{};
  bool m_stop_requested = true;
  std::atomic<u64> m_transfer_data_size{0};
};

class IOSNetPlaySession
{
public:
  IOSNetPlaySession(std::vector<std::shared_ptr<const UICommon::GameFile>> games,
                    DOLNetPlayCallbacks callbacks)
      : m_games(std::move(games))
  {
    m_ui = std::make_unique<IOSNetPlayUI>(this, callbacks, m_games);
  }

  IOSNetPlaySession(std::vector<std::string> paths, DOLNetPlayCallbacks callbacks)
  {
    for (const auto& path : paths)
    {
      bool changed = false;
      if (auto game = m_game_cache.AddOrGet(path, &changed))
        m_games.push_back(std::move(game));
    }
    m_ui = std::make_unique<IOSNetPlayUI>(this, callbacks, m_games);
  }

  bool Connect(bool host, bool traversal, const std::string& address, u16 port,
               const std::string& nickname, const std::string& traversal_server,
               u16 traversal_port, u16 traversal_port_alt, bool use_upnp)
  {
    const NetPlay::NetTraversalConfig traversal_config{traversal, traversal_server,
                                                       traversal_port, traversal_port_alt};
    if (host)
    {
      const u16 listen_port = traversal ? Config::Get(Config::NETPLAY_LISTEN_PORT) : port;
      m_server = std::make_unique<NetPlay::NetPlayServer>(listen_port, use_upnp, m_ui.get(),
                                                          traversal_config);
      m_ui->SetServer(m_server.get());
      if (!m_server->is_connected)
        return false;

      const std::string network_mode = Config::Get(Config::NETPLAY_NETWORK_MODE);
      m_server->SetHostInputAuthority(network_mode == "hostinputauthority" ||
                                      network_mode == "golf");
      m_server->AdjustPadBufferSize(Config::Get(Config::NETPLAY_BUFFER_SIZE));
      m_client = std::make_unique<NetPlay::NetPlayClient>(
          "127.0.0.1", m_server->GetPort(), m_ui.get(), nickname,
          NetPlay::NetTraversalConfig{false, traversal_server, traversal_port});
    }
    else
    {
      m_client = std::make_unique<NetPlay::NetPlayClient>(address, port, m_ui.get(), nickname,
                                                          traversal_config);
    }

    m_ui->SetClient(m_client.get());
    if (m_client->IsConnected())
      m_client->AdjustPadBufferSize(Config::Get(Config::NETPLAY_CLIENT_BUFFER_SIZE));
    return m_client->IsConnected();
  }

  NetPlay::NetPlayClient* Client() const { return m_client.get(); }
  NetPlay::NetPlayServer* Server() const { return m_server.get(); }
  IOSNetPlayUI* UI() const { return m_ui.get(); }

  std::shared_ptr<const UICommon::GameFile> FindGame(const std::string& path) const
  {
    for (const auto& game : m_games)
    {
      if (game->GetFilePath() == path)
        return game;
    }
    return {};
  }

  std::shared_ptr<const UICommon::GameFile>
  FindGame(const NetPlay::SyncIdentifier& identifier,
           NetPlay::SyncIdentifierComparison* comparison = nullptr) const
  {
    NetPlay::SyncIdentifierComparison best = NetPlay::SyncIdentifierComparison::DifferentGame;
    std::shared_ptr<const UICommon::GameFile> result;
    for (const auto& game : m_games)
    {
      const auto current = game->CompareSyncIdentifier(identifier);
      if (current < best)
      {
        best = current;
        result = game;
      }
    }
    if (comparison)
      *comparison = best;
    return result;
  }

  bool HasGameSelected() const
  {
    if (m_server && !m_server->GetSelectedGameName().empty())
      return true;
    return m_ui && m_ui->HasSelectedGame();
  }

  bool IsSelectedGameAvailable()
  {
    if (m_server && !m_server->GetSelectedGameName().empty())
      return FindGame(m_server->GetSelectedGameIdentifier()) != nullptr;
    return m_ui && m_ui->IsSelectedGameAvailable();
  }

  std::string GetSelectedGameTitle()
  {
    if (m_server && !m_server->GetSelectedGameName().empty())
      return m_server->GetSelectedGameName();
    return m_ui ? m_ui->GetSelectedGameTitle() : "";
  }

private:
  UICommon::GameFileCache m_game_cache;
  std::vector<std::shared_ptr<const UICommon::GameFile>> m_games;
  std::unique_ptr<IOSNetPlayUI> m_ui;
  std::unique_ptr<NetPlay::NetPlayServer> m_server;
  std::unique_ptr<NetPlay::NetPlayClient> m_client;
};

void IOSNetPlayUI::BootGame(const std::string& filename,
                            std::unique_ptr<BootSessionData> boot_session_data)
{
  m_stop_requested = false;
  if (m_callbacks.on_boot_game)
    m_callbacks.on_boot_game(m_callbacks.context, filename.c_str(), boot_session_data.release());
}

void IOSNetPlayUI::StopGame()
{
  if (m_stop_requested)
    return;
  m_stop_requested = true;
  if (Core::IsRunning(Core::System::GetInstance()))
    Core::QueueHostJob(&Core::Stop);
}

void IOSNetPlayUI::Update()
{
  if (!m_client)
    return;
  const auto now = std::chrono::steady_clock::now();
  if (m_last_players_update.time_since_epoch().count() != 0 &&
      now - m_last_players_update < std::chrono::milliseconds(250))
  {
    return;
  }
  m_last_players_update = now;
  std::string players;
  for (const NetPlay::Player* player : m_client->GetPlayers())
  {
    if (!players.empty())
      players += "\n";
    players += player->IsHost() ? "★ " : "• ";
    players += player->name + "  ·  " + player->revision + "  ·  " +
               std::to_string(player->ping) + " ms\n  ";
    players += NetPlay::GetPlayerMappingString(player->pid, m_client->GetPadMapping(),
                                               m_client->GetGBAConfig(),
                                               m_client->GetWiimoteMapping());
  }
  Emit(DOLNetPlayEventPlayers, players.empty() ? "Waiting for players…" : players);
}

void IOSNetPlayUI::AppendChat(const std::string& message)
{
  Emit(DOLNetPlayEventChat, message);
}

void IOSNetPlayUI::OnMsgChangeGame(const NetPlay::SyncIdentifier& identifier,
                                   const std::string& name)
{
  m_current_game = identifier;
  Emit(DOLNetPlayEventGame, name);
}

void IOSNetPlayUI::StartSelectedGame()
{
  if (!m_client)
    return;
  if (const auto game = FindGameFile(m_current_game))
    m_client->StartGame(game->GetFilePath());
  else
    Emit(DOLNetPlayEventError, "The selected game is not in the local library.");
}

void IOSNetPlayUI::OnDesync(u32 frame, const std::string& player)
{
  Emit(DOLNetPlayEventError, "Desync at frame " + std::to_string(frame) + " reported by " + player);
}

void IOSNetPlayUI::OnTraversalStateChanged(Common::TraversalClient::State state)
{
  if (!Common::g_TraversalClient)
    return;
  if (state == Common::TraversalClient::State::Failure)
    return;

  std::string message;
  if (state == Common::TraversalClient::State::Connected)
  {
    const auto id = Common::g_TraversalClient->GetHostID();
    const auto address = Common::g_TraversalClient->GetExternalAddress();
    char ip[INET6_ADDRSTRLEN] = {};
    const int family = address.isIPV6 ? AF_INET6 : AF_INET;
    if (!inet_ntop(family, address.address, ip, sizeof(ip)))
      ip[0] = '\0';
    message = "Room code: " + std::string(id.begin(), id.end()) + "\nExternal address: " + ip +
              ":" + std::to_string(address.port);
    Emit(DOLNetPlayEventTraversalConnected, message);
    return;
  }
  else if (state == Common::TraversalClient::State::Connecting)
  {
    message = "Connecting to the Dolphin traversal server…";
  }
  Emit(DOLNetPlayEventStatus, message);
}

void IOSNetPlayUI::OnTraversalError(Common::TraversalClient::FailureReason reason)
{
  int event = IsHosting() ? DOLNetPlayEventTraversalRetryableError :
                            DOLNetPlayEventTraversalFatalError;
  const char* message = IsHosting() ? "The traversal connection failed. Tap Retry to reconnect." :
                                      "The traversal connection failed. Close NetPlay and try again.";
  switch (reason)
  {
  case Common::TraversalClient::FailureReason::BadHost:
    event = DOLNetPlayEventTraversalFatalError;
    message = "Could not find the traversal server. Check the server address and network.";
    break;
  case Common::TraversalClient::FailureReason::VersionTooOld:
    event = DOLNetPlayEventTraversalFatalError;
    message = "This Dolphin version is too old for the traversal server.";
    break;
  case Common::TraversalClient::FailureReason::ServerForgotAboutUs:
    message = "The traversal server lost this session. Tap Retry to reconnect.";
    break;
  case Common::TraversalClient::FailureReason::SocketSendError:
    message = "Could not send data to the traversal server. Tap Retry to reconnect.";
    break;
  case Common::TraversalClient::FailureReason::ResendTimeout:
    message = "The traversal server timed out. Tap Retry to reconnect.";
    break;
  }
  Emit(event, message);
}

std::shared_ptr<const UICommon::GameFile>
IOSNetPlayUI::FindGameFile(const NetPlay::SyncIdentifier& identifier,
                           NetPlay::SyncIdentifierComparison* comparison)
{
  return m_session->FindGame(identifier, comparison);
}

void IOSNetPlayUI::OnIndexAdded(bool success, std::string error)
{
  Emit(success ? DOLNetPlayEventIndex : DOLNetPlayEventError,
       success ? "Listed this room in the public lobby." :
                 "Could not list the room in the public lobby: " + error);
}

void IOSNetPlayUI::OnIndexRefreshFailed(std::string error)
{
  Emit(DOLNetPlayEventError, "Public lobby listing failed: " + error);
}

void IOSNetPlayUI::SetHostWiiSyncData(std::vector<u64> titles, std::string redirect_folder)
{
  if (m_client)
    m_client->SetWiiSyncData(nullptr, std::move(titles), std::move(redirect_folder));
}
}  // namespace

extern "C" __attribute__((visibility("default"))) void*
DOLNetPlayCreate(const char* const* game_paths, size_t game_count,
                 const DOLNetPlayCallbacks* callbacks)
{
  if (!callbacks)
    return nullptr;
  std::vector<std::string> paths;
  paths.reserve(game_count);
  for (size_t i = 0; i < game_count; ++i)
    paths.push_back(FromCString(game_paths[i]));
  return new IOSNetPlaySession(std::move(paths), *callbacks);
}

extern "C" __attribute__((visibility("default"))) void*
DOLNetPlayCreateWithGames(const DOLGameFileHandle* game_file_ptrs, size_t game_count,
                         const DOLNetPlayCallbacks* callbacks)
{
  if (!callbacks)
    return nullptr;
  std::vector<std::shared_ptr<const UICommon::GameFile>> games;
  games.reserve(game_count);
  for (size_t i = 0; i < game_count; ++i)
  {
    if (game_file_ptrs && game_file_ptrs[i])
    {
      const auto* shared_ptr_ref =
          static_cast<const std::shared_ptr<const UICommon::GameFile>*>(game_file_ptrs[i]);
      if (*shared_ptr_ref)
        games.push_back(*shared_ptr_ref);
    }
  }
  return new IOSNetPlaySession(std::move(games), *callbacks);
}

extern "C" __attribute__((visibility("default"))) bool
DOLNetPlayConnect(void* opaque, bool host, bool traversal, const char* address_or_code,
                  uint16_t port, const char* nickname, const char* traversal_server,
                  uint16_t traversal_port, uint16_t traversal_port_alt, bool use_upnp)
{
  auto* session = static_cast<IOSNetPlaySession*>(opaque);
  if (!session)
    return false;
  return session->Connect(host, traversal, FromCString(address_or_code), port,
                          FromCString(nickname), FromCString(traversal_server), traversal_port,
                          traversal_port_alt, use_upnp);
}

extern "C" __attribute__((visibility("default"))) void DOLNetPlayClose(void* opaque)
{
  delete static_cast<IOSNetPlaySession*>(opaque);
}

extern "C" __attribute__((visibility("default"))) uint16_t DOLNetPlayGetPort(void* opaque)
{
  auto* session = static_cast<IOSNetPlaySession*>(opaque);
  return session && session->Server() ? session->Server()->GetPort() : 0;
}

extern "C" __attribute__((visibility("default"))) bool
DOLNetPlayGetExternalIP(char* output, size_t output_size)
{
  if (!output || output_size == 0)
    return false;
  Common::HttpRequest request;
  request.UseIPv4();
  const auto response = request.Get("https://ip.dolphin-emu.org/", {{"X-Is-Dolphin", "1"}});
  if (!response || response->empty() || response->size() >= output_size)
    return false;
  std::copy(response->begin(), response->end(), output);
  output[response->size()] = '\0';
  return true;
}

extern "C" __attribute__((visibility("default"))) bool
DOLNetPlayGetLocalIP(char* output, size_t output_size)
{
  if (!output || output_size == 0)
    return false;
  ifaddrs* interfaces = nullptr;
  if (getifaddrs(&interfaces) != 0)
    return false;
  bool found = false;
  for (const ifaddrs* current = interfaces; current; current = current->ifa_next)
  {
    if (!current->ifa_addr || (current->ifa_flags & IFF_LOOPBACK) ||
        current->ifa_addr->sa_family != AF_INET)
    {
      continue;
    }
    const auto* address = reinterpret_cast<const sockaddr_in*>(current->ifa_addr);
    if (inet_ntop(AF_INET, &address->sin_addr, output, static_cast<socklen_t>(output_size)))
    {
      found = true;
      break;
    }
  }
  freeifaddrs(interfaces);
  return found;
}

extern "C" __attribute__((visibility("default"))) bool
DOLNetPlaySetGame(void* opaque, const char* path)
{
  auto* session = static_cast<IOSNetPlaySession*>(opaque);
  if (!session || !session->Server())
    return false;
  const auto game = session->FindGame(FromCString(path));
  if (!game)
    return false;
  return session->Server()->ChangeGame(game->GetSyncIdentifier(),
                                       game->GetName(UICommon::GameFile::Variant::LongAndPossiblyCustom));
}

extern "C" __attribute__((visibility("default"))) bool
DOLNetPlayHasGameSelected(void* opaque)
{
  auto* session = static_cast<IOSNetPlaySession*>(opaque);
  return session && session->HasGameSelected();
}

extern "C" __attribute__((visibility("default"))) bool
DOLNetPlayIsSelectedGameAvailable(void* opaque)
{
  auto* session = static_cast<IOSNetPlaySession*>(opaque);
  return session && session->IsSelectedGameAvailable();
}

extern "C" __attribute__((visibility("default"))) bool
DOLNetPlayGetSelectedGameTitle(void* opaque, char* output, size_t output_size)
{
  auto* session = static_cast<IOSNetPlaySession*>(opaque);
  if (!session || !output || output_size == 0)
    return false;
  const std::string title = session->GetSelectedGameTitle();
  if (title.empty() || title.size() >= output_size)
    return false;
  std::copy(title.begin(), title.end(), output);
  output[title.size()] = '\0';
  return true;
}

extern "C" __attribute__((visibility("default"))) bool
DOLNetPlayDoAllPlayersHaveGame(void* opaque)
{
  auto* session = static_cast<IOSNetPlaySession*>(opaque);
  if (!session || !session->Client())
    return false;
  if (!session->HasGameSelected())
    return false;
  if (session->Client()->GetPlayers().empty())
    return false;
  return session->Client()->DoAllPlayersHaveGame();
}

extern "C" __attribute__((visibility("default"))) void DOLNetPlayStartGame(void* opaque)
{
  auto* session = static_cast<IOSNetPlaySession*>(opaque);
  if (session && session->Server())
    session->Server()->RequestStartGame();
}

extern "C" __attribute__((visibility("default"))) void
DOLNetPlayStartClientGame(void* opaque)
{
  auto* session = static_cast<IOSNetPlaySession*>(opaque);
  if (session)
    session->UI()->StartSelectedGame();
}

extern "C" __attribute__((visibility("default"))) void
DOLNetPlayTriggerPowerButton(void* opaque)
{
  if (opaque && Core::IsRunning(Core::System::GetInstance()))
    UICommon::TriggerSTMPowerEvent();
}

extern "C" __attribute__((visibility("default"))) void
DOLNetPlaySendChat(void* opaque, const char* message)
{
  auto* session = static_cast<IOSNetPlaySession*>(opaque);
  if (session && session->Client())
    session->Client()->SendChatMessage(FromCString(message));
}

extern "C" __attribute__((visibility("default"))) size_t
DOLNetPlayGetPlayers(void* opaque, DOLNetPlayPlayerInfo* output, size_t output_count)
{
  auto* session = static_cast<IOSNetPlaySession*>(opaque);
  if (!session || !session->Client())
    return 0;
  const auto players = session->Client()->GetPlayers();
  const size_t copied = std::min(players.size(), output_count);
  for (size_t i = 0; i < copied; ++i)
  {
    output[i].id = players[i]->pid;
    output[i].is_host = players[i]->IsHost();
    std::snprintf(output[i].name, sizeof(output[i].name), "%s", players[i]->name.c_str());
  }
  return players.size();
}

extern "C" __attribute__((visibility("default"))) bool
DOLNetPlayGetControllerMappings(void* opaque, uint8_t* gamecube_ports, size_t gamecube_count,
                                uint8_t* wii_remotes, size_t wiimote_count)
{
  auto* session = static_cast<IOSNetPlaySession*>(opaque);
  if (!session || !session->Client() || !gamecube_ports || !wii_remotes)
    return false;
  const auto& pads = session->Client()->GetPadMapping();
  const auto& wiimotes = session->Client()->GetWiimoteMapping();
  if (gamecube_count != pads.size() || wiimote_count != wiimotes.size())
    return false;
  std::copy(pads.begin(), pads.end(), gamecube_ports);
  std::copy(wiimotes.begin(), wiimotes.end(), wii_remotes);
  return true;
}

extern "C" __attribute__((visibility("default"))) bool
DOLNetPlaySetControllerMapping(void* opaque, bool wiimote, int port, uint8_t player_id)
{
  auto* session = static_cast<IOSNetPlaySession*>(opaque);
  if (!session || !session->Server() || port < 0)
    return false;
  if (wiimote)
  {
    auto mapping = session->Server()->GetWiimoteMapping();
    if (static_cast<size_t>(port) >= mapping.size())
      return false;
    mapping[port] = player_id;
    session->Server()->SetWiimoteMapping(mapping);
  }
  else
  {
    auto mapping = session->Server()->GetPadMapping();
    if (static_cast<size_t>(port) >= mapping.size())
      return false;
    mapping[port] = player_id;
    session->Server()->SetPadMapping(mapping);
  }
  return true;
}

extern "C" __attribute__((visibility("default"))) void
DOLNetPlaySetHostInputAuthority(void* opaque, bool enabled)
{
  auto* session = static_cast<IOSNetPlaySession*>(opaque);
  if (session && session->Server())
    session->Server()->SetHostInputAuthority(enabled);
}

extern "C" __attribute__((visibility("default"))) void
DOLNetPlayAdjustPadBuffer(void* opaque, int buffer, bool client_buffer)
{
  auto* session = static_cast<IOSNetPlaySession*>(opaque);
  if (!session || buffer < 0)
    return;
  if (client_buffer && session->Client())
    session->Client()->AdjustPadBufferSize(static_cast<u32>(buffer));
  else if (session->Server())
    session->Server()->AdjustPadBufferSize(static_cast<u32>(buffer));
}

extern "C" __attribute__((visibility("default"))) bool
DOLNetPlayBrowse(DOLNetPlaySessionCallback callback, void* context)
{
  if (!callback)
    return false;
  NetPlayIndex index;
  auto sessions = index.List();
  if (!sessions)
    return false;
  for (const NetPlaySession& session : *sessions)
  {
    callback(context, session.name.c_str(), session.region.c_str(), session.method.c_str(),
             session.server_id.c_str(), session.game_id.c_str(), session.version.c_str(),
             session.player_count, session.port, session.has_password, session.in_game);
  }
  return true;
}

extern "C" __attribute__((visibility("default"))) bool
DOLNetPlayDecryptSessionId(const char* server_id, const char* password, char* output,
                           size_t output_size)
{
  if (!server_id || !password || !output || output_size == 0)
    return false;
  NetPlaySession session;
  session.server_id = server_id;
  const auto decrypted = session.DecryptID(password);
  if (!decrypted || decrypted->size() >= output_size)
    return false;
  std::copy(decrypted->begin(), decrypted->end(), output);
  output[decrypted->size()] = '\0';
  return true;
}

extern "C" __attribute__((visibility("default"))) bool DOLNetPlayRetryTraversal(void* opaque)
{
  auto* session = static_cast<IOSNetPlaySession*>(opaque);
  if (!session || !session->Server() || !Common::g_TraversalClient)
    return false;
  Common::g_TraversalClient->ReconnectToServer();
  return true;
}
