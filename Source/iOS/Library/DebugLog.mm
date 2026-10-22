// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DebugLog.h"

#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/utsname.h>
#include <unistd.h>

#include <initializer_list>
#include <memory>
#include <mutex>
#include <string>

#include "Common/Logging/LogManager.h"

namespace
{
// A single session log. Everything after this is dropped so a NetPlay session cannot
// fill the device's storage.
constexpr off_t MAX_LOG_BYTES = 4 * 1024 * 1024;

std::mutex s_log_mutex;
int s_log_fd = -1;
off_t s_log_bytes = 0;
bool s_log_full = false;
bool s_log_file_requested = false;
volatile sig_atomic_t s_in_crash_handler = 0;

NSString* LogPath()
{
  static NSString* const s_path = [] {
    NSArray<NSString*>* directories =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString* directory = directories.firstObject;
    if (directory.length == 0)
      directory = NSTemporaryDirectory();
    return [directory stringByAppendingPathComponent:@"events.log"];
  }();
  return s_path;
}

void FormatTimestamp(char* buffer, size_t size)
{
  struct timeval now;
  gettimeofday(&now, nullptr);

  struct tm local;
  const time_t seconds = now.tv_sec;
  localtime_r(&seconds, &local);

  snprintf(buffer, size, "%04d-%02d-%02d %02d:%02d:%02d.%03d", local.tm_year + 1900,
           local.tm_mon + 1, local.tm_mday, local.tm_hour, local.tm_min, local.tm_sec,
           static_cast<int>(now.tv_usec / 1000));
}

bool EnsureOpenLocked()
{
  if (s_log_fd >= 0)
    return true;

  // The first open of a session truncates the file; later opens append to it.
  const int flags = O_WRONLY | O_CREAT | (s_log_file_requested ? 0 : O_TRUNC);
  s_log_fd = open(LogPath().fileSystemRepresentation, flags, 0644);
  s_log_file_requested = true;
  s_log_bytes = 0;
  s_log_full = false;

  if (s_log_fd < 0)
    return false;

  const off_t end = lseek(s_log_fd, 0, SEEK_END);
  if (end > 0)
    s_log_bytes = end;

  return true;
}

void AppendBytes(const char* bytes, size_t length)
{
  if (!bytes || length == 0)
    return;

  std::lock_guard lock(s_log_mutex);
  if (!EnsureOpenLocked() || s_log_full)
    return;

  if (s_log_bytes + static_cast<off_t>(length) > MAX_LOG_BYTES)
  {
    static const char note[] = "\n[log] events.log reached its 4 MiB limit; output dropped.\n";
    (void)write(s_log_fd, note, sizeof(note) - 1);
    s_log_full = true;
    return;
  }

  const ssize_t written = write(s_log_fd, bytes, length);
  if (written > 0)
    s_log_bytes += written;
}

void AppendLine(const char* tag, const char* text)
{
  if (!text)
    text = "";

  char stamp[40];
  FormatTimestamp(stamp, sizeof(stamp));

  std::string line;
  line.reserve(strlen(text) + 128);
  line += '[';
  line += stamp;
  line += "] ";
  if ([NSThread isMainThread])
    line += "main ";
  else
    line += "bg   ";
  if (tag && *tag)
  {
    line += '[';
    line += tag;
    line += "] ";
  }
  line += text;
  if (line.empty() || line.back() != '\n')
    line.push_back('\n');

  AppendBytes(line.data(), line.size());
}

void AppendLineV(const char* tag, NSString* format, va_list arguments)
{
  NSString* text = [[NSString alloc] initWithFormat:format arguments:arguments];
  AppendLine(tag, text.UTF8String);
}

void AppendLineF(const char* tag, NSString* format, ...)
{
  va_list arguments;
  va_start(arguments, format);
  AppendLineV(tag, format, arguments);
  va_end(arguments);
}

const char* SignalName(int signal_number)
{
  switch (signal_number)
  {
  case SIGABRT:
    return "SIGABRT";
  case SIGBUS:
    return "SIGBUS";
  case SIGFPE:
    return "SIGFPE";
  case SIGILL:
    return "SIGILL";
  case SIGSEGV:
    return "SIGSEGV";
  case SIGTRAP:
    return "SIGTRAP";
  default:
    return "signal";
  }
}

// Writes straight to the file descriptor: this runs while the process is dying, so it
// cannot take the log mutex or touch Foundation.
void WriteCrashLine(const char* text)
{
  if (s_log_fd < 0 || !text)
    return;
  (void)write(s_log_fd, text, strlen(text));
}

void HandleSignal(int signal_number, siginfo_t* info, void*)
{
  if (s_in_crash_handler)
  {
    signal(signal_number, SIG_DFL);
    raise(signal_number);
    return;
  }
  s_in_crash_handler = 1;

  char buffer[256];
  const int length = snprintf(buffer, sizeof(buffer), "\n*** FATAL %s (%d) at address %p ***\n",
                              SignalName(signal_number), signal_number,
                              info ? info->si_addr : nullptr);
  if (length > 0)
    WriteCrashLine(buffer);

  void* frames[128];
  const int count = backtrace(frames, 128);
  if (s_log_fd >= 0)
    backtrace_symbols_fd(frames, count, s_log_fd);

  WriteCrashLine("*** end of crash backtrace ***\n");

  signal(signal_number, SIG_DFL);
  raise(signal_number);
}

void HandleException(NSException* exception)
{
  AppendLine("CRASH", "Uncaught Objective-C exception");
  AppendLineF("CRASH", @"%@: %@", exception.name ?: @"Exception", exception.reason ?: @"");

  for (NSString* line in exception.callStackSymbols ?: @[])
    AppendLine("CRASH", line.UTF8String);

  NSArray<NSString*>* thread_stacks = [NSThread callStackSymbols];
  if (thread_stacks.count)
  {
    AppendLine("CRASH", "Current thread backtrace");
    for (NSString* line in thread_stacks)
      AppendLine("CRASH", line.UTF8String);
  }
}

// Dolphin's own logging is the most useful source of NetPlay diagnostics, so mirror
// it into events.log through the unused log window listener slot.
class EventsLogListener final : public Common::Log::LogListener
{
public:
  void Log(Common::Log::LogLevel level, const char* msg) override
  {
    const char* tag = "CORE";
    switch (level)
    {
    case Common::Log::LogLevel::LERROR:
      tag = "CORE-ERROR";
      break;
    case Common::Log::LogLevel::LWARNING:
      tag = "CORE-WARN";
      break;
    default:
      break;
    }
    AppendLine(tag, msg);
  }
};
}  // namespace

NSString* DOLLogFilePath(void)
{
  return LogPath();
}

void DOLLogStartSession(void)
{
  {
    std::lock_guard lock(s_log_mutex);
    if (s_log_fd >= 0)
    {
      close(s_log_fd);
      s_log_fd = -1;
    }
    // Force the next open to truncate the previous session's log.
    s_log_file_requested = false;
    s_log_full = false;
    s_log_bytes = 0;
    EnsureOpenLocked();
  }

  NSBundle* bundle = [NSBundle mainBundle];
  NSString* version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
  NSString* build = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";

  // UIKit is not linked into libdolphin, so identify the device through uname() and
  // NSProcessInfo instead of UIDevice.
  struct utsname system_info = {};
  NSString* machine = uname(&system_info) == 0 ?
                         [NSString stringWithUTF8String:system_info.machine] :
                         @"?";
  NSString* system_version = [NSProcessInfo processInfo].operatingSystemVersionString ?: @"?";

  AppendLine("=====", "DolphiniOS debug log");
  AppendLineF("APP", @"Version %@ (%@)", version, build);
  AppendLineF("APP", @"Device %@, %@", machine, system_version);
  AppendLineF("APP", @"Log file %@", DOLLogFilePath());
  AppendLine("=====", "Log truncated for this launch");
}

void DOLLogInstallCrashHandlers(void)
{
  NSSetUncaughtExceptionHandler(&HandleException);

  // Keep the descriptor open so the signal handler can write without allocating.
  {
    std::lock_guard lock(s_log_mutex);
    if (!EnsureOpenLocked())
      return;
  }

  static struct sigaction action = {};
  action.sa_sigaction = &HandleSignal;
  action.sa_flags = SA_SIGINFO;
  sigemptyset(&action.sa_mask);

  for (const int signal_number : {SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP})
    sigaction(signal_number, &action, nullptr);

  AppendLine("LOG", "Crash handlers installed");
}

void DOLLogEnableCoreLogging(void)
{
  Common::Log::LogManager* manager = Common::Log::LogManager::GetInstance();
  if (!manager)
    return;

  manager->RegisterListener(Common::Log::LogListener::LOG_WINDOW_LISTENER,
                            std::make_unique<EventsLogListener>());
  manager->EnableListener(Common::Log::LogListener::LOG_WINDOW_LISTENER, true);

  for (const Common::Log::LogType type :
       {Common::Log::LogType::NETPLAY, Common::Log::LogType::CORE, Common::Log::LogType::BOOT,
        Common::Log::LogType::CONTROLLERINTERFACE,
        Common::Log::LogType::SERIALINTERFACE})
  {
    manager->SetEnable(type, true);
  }

  if (manager->GetLogLevel() < Common::Log::LogLevel::LINFO)
    manager->SetLogLevel(Common::Log::LogLevel::LINFO);

  AppendLine("LOG", "Dolphin core logging mirrored into events.log");
}

void DOLLogWrite(const char* tag, NSString* message)
{
  AppendLine(tag, message.UTF8String);
}

void DOLLogWriteF(const char* tag, NSString* format, ...)
{
  va_list arguments;
  va_start(arguments, format);
  AppendLineV(tag, format, arguments);
  va_end(arguments);
}

@implementation DOLDebugLog

+ (void)logTag:(NSString*)tag message:(NSString*)message
{
  AppendLine(tag.UTF8String, message.UTF8String);
}

+ (NSString*)filePath
{
  return DOLLogFilePath();
}

@end
