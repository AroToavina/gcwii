// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "NetPlayViewController.h"

#import <algorithm>
#import <memory>
#import <string>
#import <vector>

#import "Common/FileUtil.h"
#import "Core/Config/NetplaySettings.h"
#import "Core/Config/MainSettings.h"
#import "Core/Boot/Boot.h"
#import "Core/Core.h"
#import "Core/System.h"

#import "EmulationBootParameter.h"
#import "EmulationCoordinator.h"
#import "FoundationStringUtil.h"
#import "GameFileCacheManager.h"
#import "GameFilePtrWrapper.h"
#import "HostNotifications.h"
#import "NetPlay.h"
#import "LocalizationUtil.h"
#import "UICommon/GameFile.h"

@class NetPlayViewController;
@class NetPlayGamePickerViewController;

@protocol NetPlayGamePickerViewControllerDelegate <NSObject>
- (void)gamePicker:(NetPlayGamePickerViewController*)picker
    didSelectGame:(GameFilePtrWrapper*)game;
@end

// A searchable list instead of an action sheet: libraries can hold hundreds of
// games, and the host has to be able to pick one before opening the room as well
// as from the lobby afterwards.
@interface NetPlayGamePickerViewController : UITableViewController <UISearchResultsUpdating>

@property(nonatomic, weak) id<NetPlayGamePickerViewControllerDelegate> pickerDelegate;
@property(nonatomic, strong) NSArray<GameFilePtrWrapper*>* games;
@property(nonatomic, strong, nullable) GameFilePtrWrapper* selectedGame;

- (instancetype)initWithGames:(NSArray<GameFilePtrWrapper*>*)games
                 selectedGame:(nullable GameFilePtrWrapper*)selectedGame;

@end

@interface NetPlayViewController () <NetPlayGamePickerViewControllerDelegate>
- (void)handleNetPlayEvent:(int)event message:(NSString*)message;
- (BOOL)netPlayBootGame:(NSString*)path sessionData:(BootSessionData*)sessionData;
- (void)presentConnectionLostAlertIfNeeded;
- (void)presentTraversalFatalErrorIfNeeded;
- (void)retryTraversalTapped;
- (void)joinListedSessionAtIndex:(NSUInteger)index password:(nullable NSString*)password;
- (void)updateSessionControlsForGameState:(bool)game_running;
- (void)hideSessionSheet;
- (void)selectGame;
- (void)setSelectedGame:(nullable GameFilePtrWrapper*)wrapper;
- (void)updateSetupGameButton;
- (void)updateSessionGameState;
- (NSArray<GameFilePtrWrapper*>*)libraryGames;
@end

namespace
{
NetPlayViewController* s_active_netplay_controller = nil;

NSString* ToNSString(const std::string& value)
{
  return CppToFoundationString(value);
}

struct ListedSession
{
  std::string name;
  std::string region;
  std::string method;
  std::string server_id;
  std::string game;
  std::string version;
  int player_count;
  int port;
  bool has_password;
  bool in_game;
};

void CollectSession(void* context, const char* name, const char* region, const char* method,
                    const char* server_id, const char* game, const char* version,
                    int player_count, int port, bool has_password, bool in_game)
{
  auto* sessions = static_cast<std::vector<ListedSession>*>(context);
  sessions->push_back({name ? name : "", region ? region : "", method ? method : "",
                       server_id ? server_id : "", game ? game : "", version ? version : "",
                       player_count, port, has_password, in_game});
}

void NetPlayEvent(void* context, int event, const char* message)
{
  __weak NetPlayViewController* controller = (__bridge NetPlayViewController*)context;
  NSString* text = message ? [NSString stringWithUTF8String:message] : @"";
  dispatch_async(dispatch_get_main_queue(), ^{
    [controller handleNetPlayEvent:event message:text];
  });
}

void NetPlayBoot(void* context, const char* path, void* boot_session_data)
{
  __weak NetPlayViewController* controller = (__bridge NetPlayViewController*)context;
  NSString* game_path = path ? [NSString stringWithUTF8String:path] : @"";
  BootSessionData* raw_session_data = static_cast<BootSessionData*>(boot_session_data);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (![controller netPlayBootGame:game_path sessionData:raw_session_data])
    {
      delete raw_session_data;
    }
  });
}
}  // namespace

static UIViewController* DOLTopViewController(void)
{
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes)
  {
    if (![scene isKindOfClass:[UIWindowScene class]])
      continue;

    for (UIWindow* window in ((UIWindowScene*)scene).windows)
    {
      if (!window.isKeyWindow)
        continue;

      UIViewController* controller = window.rootViewController;
      while (controller.presentedViewController != nil)
        controller = controller.presentedViewController;

      return controller;
    }
  }

  return nil;
}

@implementation NetPlayGamePickerViewController {
  NSArray<GameFilePtrWrapper*>* _filteredGames;
  UISearchController* _searchController;
}

- (instancetype)initWithGames:(NSArray<GameFilePtrWrapper*>*)games
                 selectedGame:(nullable GameFilePtrWrapper*)selectedGame
{
  if (self = [super initWithStyle:UITableViewStylePlain])
  {
    _games = games ?: @[];
    _filteredGames = _games;
    _selectedGame = selectedGame;
    self.title = @"Select Game";
  }
  return self;
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  self.tableView.rowHeight = 56;
  self.navigationItem.leftBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                    target:self
                                                    action:@selector(cancelTapped)];

  _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
  _searchController.searchResultsUpdater = self;
  _searchController.obscuresBackgroundDuringPresentation = NO;
  self.navigationItem.searchController = _searchController;
  self.navigationItem.hidesSearchBarWhenScrolling = NO;
  self.definesPresentationContext = YES;
}

- (void)cancelTapped
{
  [self dismissViewControllerAnimated:true completion:nil];
}

- (void)updateSearchResultsForSearchController:(UISearchController*)searchController
{
  NSString* query = [searchController.searchBar.text
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (query.length == 0)
  {
    _filteredGames = _games;
  }
  else
  {
    NSMutableArray<GameFilePtrWrapper*>* matches = [[NSMutableArray alloc] init];
    for (GameFilePtrWrapper* wrapper in _games)
    {
      NSString* title =
          ToNSString(wrapper.gameFile->GetName(UICommon::GameFile::Variant::LongAndPossiblyCustom));
      NSString* game_id = ToNSString(wrapper.gameFile->GetGameID());
      if ([title rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
          [game_id rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound)
      {
        [matches addObject:wrapper];
      }
    }
    _filteredGames = matches;
  }
  [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView
{
  return 1;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section
{
  return static_cast<NSInteger>(_filteredGames.count);
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath
{
  static NSString* const identifier = @"NetPlayGameCell";
  UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:identifier];
  if (!cell)
  {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                 reuseIdentifier:identifier];
  }

  GameFilePtrWrapper* wrapper = _filteredGames[static_cast<NSUInteger>(indexPath.row)];
  cell.textLabel.text =
      ToNSString(wrapper.gameFile->GetName(UICommon::GameFile::Variant::LongAndPossiblyCustom));
  cell.detailTextLabel.text =
      [NSString stringWithFormat:@"%@ · %@", ToNSString(wrapper.gameFile->GetGameID()),
                                 ToNSString(wrapper.gameFile->GetFilePath()).lastPathComponent];
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  cell.accessoryType =
      wrapper == _selectedGame ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
  return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath
{
  [tableView deselectRowAtIndexPath:indexPath animated:true];
  GameFilePtrWrapper* wrapper = _filteredGames[static_cast<NSUInteger>(indexPath.row)];
  _selectedGame = wrapper;
  [tableView reloadData];
  [self.pickerDelegate gamePicker:self didSelectGame:wrapper];
}

@end

@implementation NetPlayViewController {
  UISegmentedControl* _roleControl;
  UISegmentedControl* _connectionControl;
  UITextField* _nicknameField;
  UITextField* _addressField;
  UITextField* _portField;
  UITextField* _roomNameField;
  UITextField* _roomPasswordField;
  UILabel* _statusLabel;
  UILabel* _sessionStatusLabel;
  UIButton* _retryTraversalButton;
  UIButton* _shareJoinInfoButton;
  UILabel* _playersLabel;
  UILabel* _gameLabel;
  UITextView* _chatView;
  UITextField* _chatField;
  UIButton* _connectButton;
  UIButton* _changeGameButton;
  UIButton* _startButton;
  UISwitch* _upnpSwitch;
  UISwitch* _publicRoomSwitch;
  UISegmentedControl* _regionControl;
  NSMutableArray<UIButton*>* _mappingButtons;
  UISegmentedControl* _networkModeControl;
  UIStepper* _serverBufferControl;
  UIStepper* _clientBufferControl;
  UILabel* _serverBufferLabel;
  UILabel* _clientBufferLabel;
  UIStackView* _setupStack;
  UIStackView* _sessionStack;
  NSArray<GameFilePtrWrapper*>* _games;
  GameFilePtrWrapper* _selectedGame;
  UIButton* _setupGameButton;
  std::vector<ListedSession> _listedSessions;
  void* _nativeSession;
  void* _callbackContext;
  bool _connectionInProgress;
  bool _closeRequested;
  bool _connectionLostPending;
  NSString* _pendingTraversalFatalError;
}

- (instancetype)initWithDelegate:(id<NetPlayViewControllerDelegate>)delegate
{
  if (self = [super init])
  {
    self.delegate = delegate;
    self.modalPresentationStyle = UIModalPresentationFormSheet;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(emulationEnded)
                                                 name:DOLEmulationDidEndNotification
                                               object:nil];
  }
  return self;
}

+ (instancetype)activeSessionController
{
  return s_active_netplay_controller;
}

- (void)presentFromViewController:(UIViewController*)viewController
{
  if (!viewController || self.presentingViewController != nil)
    return;

  UINavigationController* navigationController =
      [[UINavigationController alloc] initWithRootViewController:self];
  navigationController.modalPresentationStyle = UIModalPresentationFormSheet;
  [viewController presentViewController:navigationController animated:true completion:nil];
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated
{
  [super viewWillAppear:animated];

  const bool game_running = Core::IsRunning(Core::System::GetInstance());

  if (game_running)
  {
    // While a game is running the session screen acts as an in-game panel, so the
    // close button only hides it instead of tearing the session down.
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(hideSessionSheet)];
  }
  else
  {
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(closeSession)];
  }

  [self updateSessionControlsForGameState:game_running];
}

- (void)viewDidAppear:(BOOL)animated
{
  [super viewDidAppear:animated];
  [self presentConnectionLostAlertIfNeeded];
  [self presentTraversalFatalErrorIfNeeded];
}

- (void)updateSessionControlsForGameState:(bool)game_running
{
  const bool hosting = _roleControl.selectedSegmentIndex == 1;

  // Starting a second game, changing the game, or remapping controllers is only
  // meaningful while the session is still in its lobby.
  _startButton.hidden = game_running || !hosting;
  _shareJoinInfoButton.hidden = game_running || !hosting;
  _networkModeControl.hidden = game_running || !hosting;
  _changeGameButton.hidden = game_running || !hosting;
  _serverBufferLabel.hidden = game_running || !hosting;
  _serverBufferControl.hidden = game_running || !hosting;

  for (UIButton* button in _mappingButtons)
    button.hidden = game_running || !hosting;
}

- (void)hideSessionSheet
{
  [self dismissViewControllerAnimated:true completion:nil];
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  self.title = @"NetPlay";
  self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                           target:self
                           action:@selector(closeSession)];

  UITapGestureRecognizer* dismissTap =
      [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
  dismissTap.cancelsTouchesInView = NO;
  [self.view addGestureRecognizer:dismissTap];

  UIScrollView* scroll = [[UIScrollView alloc] init];
  scroll.translatesAutoresizingMaskIntoConstraints = false;
  [self.view addSubview:scroll];
  [NSLayoutConstraint activateConstraints:@[
    [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
  ]];

  UIStackView* content = [[UIStackView alloc] init];
  content.axis = UILayoutConstraintAxisVertical;
  content.spacing = 16;
  content.translatesAutoresizingMaskIntoConstraints = false;
  [scroll addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
    [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
    [content.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:20],
    [content.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-20],
  ]];

  _setupStack = [[UIStackView alloc] init];
  _setupStack.axis = UILayoutConstraintAxisVertical;
  _setupStack.spacing = 14;
  [content addArrangedSubview:_setupStack];

  _roleControl = [[UISegmentedControl alloc] initWithItems:@[@"Join", @"Host"]];
  _roleControl.selectedSegmentIndex = 0;
  [_roleControl addTarget:self action:@selector(updatePlaceholders)
         forControlEvents:UIControlEventValueChanged];
  [_setupStack addArrangedSubview:_roleControl];

  _setupGameButton = [UIButton buttonWithType:UIButtonTypeSystem];
  _setupGameButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
  _setupGameButton.titleLabel.numberOfLines = 2;
  _setupGameButton.titleLabel.textAlignment = NSTextAlignmentLeft;
  [_setupGameButton addTarget:self action:@selector(selectGame)
             forControlEvents:UIControlEventTouchUpInside];
  [_setupStack addArrangedSubview:_setupGameButton];

  _connectionControl = [[UISegmentedControl alloc] initWithItems:@[@"Direct", @"Traversal"]];
  _connectionControl.selectedSegmentIndex =
      Config::Get(Config::NETPLAY_TRAVERSAL_CHOICE) == "traversal" ? 1 : 0;
  [_connectionControl addTarget:self action:@selector(updatePlaceholders)
               forControlEvents:UIControlEventValueChanged];
  [_setupStack addArrangedSubview:_connectionControl];

  _nicknameField = [self textFieldWithPlaceholder:@"Nickname"];
  _nicknameField.text = ToNSString(Config::Get(Config::NETPLAY_NICKNAME));
  [_setupStack addArrangedSubview:_nicknameField];
  _addressField = [self textFieldWithPlaceholder:@"IP address or room code"];
  [_setupStack addArrangedSubview:_addressField];
  _portField = [self textFieldWithPlaceholder:@"Port"];
  _portField.keyboardType = UIKeyboardTypeNumberPad;
  [_setupStack addArrangedSubview:_portField];

  UIStackView* upnpRow = [[UIStackView alloc] init];
  upnpRow.axis = UILayoutConstraintAxisHorizontal;
  upnpRow.spacing = 10;
  UILabel* upnpLabel = [[UILabel alloc] init];
  upnpLabel.text = @"Use UPnP for direct hosting";
  _upnpSwitch = [[UISwitch alloc] init];
  _upnpSwitch.on = Config::Get(Config::NETPLAY_USE_UPNP);
  [upnpRow addArrangedSubview:upnpLabel];
  [upnpRow addArrangedSubview:_upnpSwitch];
  [_setupStack addArrangedSubview:upnpRow];

  UIStackView* publicRoomRow = [[UIStackView alloc] init];
  publicRoomRow.axis = UILayoutConstraintAxisHorizontal;
  publicRoomRow.spacing = 10;
  UILabel* publicRoomLabel = [[UILabel alloc] init];
  publicRoomLabel.text = @"List this room in the public lobby";
  publicRoomLabel.numberOfLines = 2;
  _publicRoomSwitch = [[UISwitch alloc] init];
  _publicRoomSwitch.on = Config::Get(Config::NETPLAY_USE_INDEX);
  [_publicRoomSwitch addTarget:self action:@selector(updatePlaceholders)
              forControlEvents:UIControlEventValueChanged];
  [publicRoomRow addArrangedSubview:publicRoomLabel];
  [publicRoomRow addArrangedSubview:_publicRoomSwitch];
  [_setupStack addArrangedSubview:publicRoomRow];

  _roomNameField = [self textFieldWithPlaceholder:@"Public room name"];
  _roomNameField.text = ToNSString(Config::Get(Config::NETPLAY_INDEX_NAME));
  [_setupStack addArrangedSubview:_roomNameField];
  _regionControl = [[UISegmentedControl alloc] initWithItems:@[@"AF", @"EA", @"EU", @"NA", @"OC", @"SA", @"CN"]];
  const std::string region = Config::Get(Config::NETPLAY_INDEX_REGION);
  NSArray<NSString*>* regions = @[@"AF", @"EA", @"EU", @"NA", @"OC", @"SA", @"CN"];
  const NSUInteger region_index = [regions indexOfObject:ToNSString(region)];
  _regionControl.selectedSegmentIndex = region_index == NSNotFound ? 2 : (NSInteger)region_index;
  [_setupStack addArrangedSubview:_regionControl];
  _roomPasswordField = [self textFieldWithPlaceholder:@"Optional room password"];
  _roomPasswordField.secureTextEntry = true;
  _roomPasswordField.text = ToNSString(Config::Get(Config::NETPLAY_INDEX_PASSWORD));
  [_setupStack addArrangedSubview:_roomPasswordField];

  UIButton* browse = [UIButton buttonWithType:UIButtonTypeSystem];
  [browse setTitle:@"Browse public sessions" forState:UIControlStateNormal];
  [browse addTarget:self action:@selector(browseSessions) forControlEvents:UIControlEventTouchUpInside];
  [_setupStack addArrangedSubview:browse];

  _connectButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [_connectButton setTitle:@"Connect" forState:UIControlStateNormal];
  [_connectButton addTarget:self action:@selector(connectTapped) forControlEvents:UIControlEventTouchUpInside];
  [_setupStack addArrangedSubview:_connectButton];

  _statusLabel = [[UILabel alloc] init];
  _statusLabel.numberOfLines = 0;
  _statusLabel.textColor = UIColor.secondaryLabelColor;
  [_setupStack addArrangedSubview:_statusLabel];

  _sessionStack = [[UIStackView alloc] init];
  _sessionStack.axis = UILayoutConstraintAxisVertical;
  _sessionStack.spacing = 12;
  _sessionStack.hidden = true;
  [content addArrangedSubview:_sessionStack];

  _sessionStatusLabel = [[UILabel alloc] init];
  _sessionStatusLabel.numberOfLines = 0;
  _sessionStatusLabel.textColor = UIColor.secondaryLabelColor;
  [_sessionStack addArrangedSubview:_sessionStatusLabel];

  _retryTraversalButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [_retryTraversalButton setTitle:@"Retry traversal connection" forState:UIControlStateNormal];
  [_retryTraversalButton addTarget:self action:@selector(retryTraversalTapped)
                  forControlEvents:UIControlEventTouchUpInside];
  _retryTraversalButton.hidden = true;
  [_sessionStack addArrangedSubview:_retryTraversalButton];

  _shareJoinInfoButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [_shareJoinInfoButton setTitle:@"Share join information" forState:UIControlStateNormal];
  [_shareJoinInfoButton addTarget:self action:@selector(shareJoinInfo)
                 forControlEvents:UIControlEventTouchUpInside];
  _shareJoinInfoButton.hidden = true;
  [_sessionStack addArrangedSubview:_shareJoinInfoButton];

  _gameLabel = [[UILabel alloc] init];
  _gameLabel.text = @"Waiting for host to select a game";
  _gameLabel.numberOfLines = 0;
  _gameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
  [_sessionStack addArrangedSubview:_gameLabel];

  _playersLabel = [[UILabel alloc] init];
  _playersLabel.text = @"Waiting for players…";
  _playersLabel.numberOfLines = 0;
  [_sessionStack addArrangedSubview:_playersLabel];

  _startButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [_startButton setTitle:@"Start game" forState:UIControlStateNormal];
  [_startButton addTarget:self action:@selector(startGame) forControlEvents:UIControlEventTouchUpInside];
  _startButton.hidden = true;
  [_sessionStack addArrangedSubview:_startButton];

  _networkModeControl = [[UISegmentedControl alloc] initWithItems:@[@"Fair delay", @"Host input"]];
  const std::string network_mode = Config::Get(Config::NETPLAY_NETWORK_MODE);
  _networkModeControl.selectedSegmentIndex = network_mode == "fixeddelay" ? 0 : 1;
  [_networkModeControl addTarget:self action:@selector(networkModeChanged)
                forControlEvents:UIControlEventValueChanged];
  [_sessionStack addArrangedSubview:_networkModeControl];
  _networkModeControl.hidden = true;

  _serverBufferLabel = [[UILabel alloc] init];
  _serverBufferControl = [self bufferStepperWithValue:Config::Get(Config::NETPLAY_BUFFER_SIZE)
                                               action:@selector(serverBufferChanged)];
  [_sessionStack addArrangedSubview:_serverBufferLabel];
  [_sessionStack addArrangedSubview:_serverBufferControl];
  _clientBufferLabel = [[UILabel alloc] init];
  _clientBufferControl = [self bufferStepperWithValue:Config::Get(Config::NETPLAY_CLIENT_BUFFER_SIZE)
                                               action:@selector(clientBufferChanged)];
  [_sessionStack addArrangedSubview:_clientBufferLabel];
  [_sessionStack addArrangedSubview:_clientBufferControl];
  [self updateBufferLabels];

  _mappingButtons = [[NSMutableArray alloc] init];
  for (NSInteger i = 0; i < 8; ++i)
  {
    UIButton* mapping = [UIButton buttonWithType:UIButtonTypeSystem];
    mapping.tag = i;
    mapping.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [mapping addTarget:self action:@selector(controllerMappingTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_mappingButtons addObject:mapping];
    [_sessionStack addArrangedSubview:mapping];
  }

  _changeGameButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [_changeGameButton setTitle:@"Select game" forState:UIControlStateNormal];
  [_changeGameButton addTarget:self action:@selector(selectGame) forControlEvents:UIControlEventTouchUpInside];
  [_changeGameButton setContentHorizontalAlignment:UIControlContentHorizontalAlignmentLeading];
  [_sessionStack addArrangedSubview:_changeGameButton];

  _chatView = [[UITextView alloc] init];
  _chatView.editable = false;
  _chatView.layer.borderWidth = 1;
  _chatView.layer.borderColor = UIColor.separatorColor.CGColor;
  _chatView.layer.cornerRadius = 8;
  [_sessionStack addArrangedSubview:_chatView];
  [_chatView.heightAnchor constraintGreaterThanOrEqualToConstant:180].active = true;

  UIStackView* chatRow = [[UIStackView alloc] init];
  chatRow.axis = UILayoutConstraintAxisHorizontal;
  chatRow.spacing = 8;
  _chatField = [self textFieldWithPlaceholder:@"Message"];
  _chatField.returnKeyType = UIReturnKeySend;
  [chatRow addArrangedSubview:_chatField];
  UIButton* send = [UIButton buttonWithType:UIButtonTypeSystem];
  [send setTitle:@"Send" forState:UIControlStateNormal];
  [send addTarget:self action:@selector(sendChat) forControlEvents:UIControlEventTouchUpInside];
  [chatRow addArrangedSubview:send];
  [_sessionStack addArrangedSubview:chatRow];

  [self updatePlaceholders];
}

- (UIToolbar*)keyboardDoneToolbar
{
  UIToolbar* toolbar =
      [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, UIScreen.mainScreen.bounds.size.width, 44)];
  UIBarButtonItem* flex = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                           target:nil
                           action:nil];
  UIBarButtonItem* done = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                           target:self
                           action:@selector(dismissKeyboard)];
  toolbar.items = @[flex, done];
  [toolbar sizeToFit];
  return toolbar;
}

- (void)dismissKeyboard
{
  [self.view endEditing:YES];
}

- (UITextField*)textFieldWithPlaceholder:(NSString*)placeholder
{
  UITextField* field = [[UITextField alloc] init];
  field.borderStyle = UITextBorderStyleRoundedRect;
  field.placeholder = placeholder;
  field.autocorrectionType = UITextAutocorrectionTypeNo;
  field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  field.clearButtonMode = UITextFieldViewModeWhileEditing;
  field.delegate = self;
  field.returnKeyType = UIReturnKeyDone;
  field.inputAccessoryView = [self keyboardDoneToolbar];
  return field;
}

- (void)updatePlaceholders
{
  const bool traversal = _connectionControl.selectedSegmentIndex == 1;
  const bool hosting = _roleControl.selectedSegmentIndex == 1;
  _setupGameButton.hidden = !hosting;
  [self updateSetupGameButton];
  _addressField.placeholder = traversal ? @"8-character room code" : @"Host IP address";
  if (hosting)
  {
    _addressField.hidden = true;
    _publicRoomSwitch.superview.hidden = false;
    _roomNameField.hidden = !_publicRoomSwitch.on;
    _regionControl.hidden = !_publicRoomSwitch.on;
    _roomPasswordField.hidden = !_publicRoomSwitch.on;
    _portField.placeholder = traversal ? @"Traversal listen port" : @"Host port";
    const u16 port = traversal ? Config::Get(Config::NETPLAY_LISTEN_PORT) :
                                 Config::Get(Config::NETPLAY_HOST_PORT);
    _portField.text = [NSString stringWithFormat:@"%u", port];
  }
  else
  {
    _addressField.hidden = false;
    _publicRoomSwitch.superview.hidden = true;
    _roomNameField.hidden = true;
    _regionControl.hidden = true;
    _roomPasswordField.hidden = true;
    _addressField.text = ToNSString(traversal ? Config::Get(Config::NETPLAY_HOST_CODE) :
                                               Config::Get(Config::NETPLAY_ADDRESS));
    _portField.placeholder = @"Port";
    _portField.text = [NSString stringWithFormat:@"%u", Config::Get(Config::NETPLAY_CONNECT_PORT)];
  }
}

- (void)connectTapped
{
  if (_nativeSession)
    return;
  const bool hosting = _roleControl.selectedSegmentIndex == 1;
  const bool traversal = _connectionControl.selectedSegmentIndex == 1;
  NSString* nickname = _nicknameField.text.length ? _nicknameField.text : @"Player";
  if (hosting && _publicRoomSwitch.on &&
      [_roomNameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0)
  {
    [self netPlayError:@"Enter a room name before publishing this session."];
    return;
  }
  NSString* endpoint = _addressField.text ?: @"";
  NSInteger port = _portField.text.integerValue;
  if (port < 1 || port > 65535)
  {
    port = hosting ? (traversal ? Config::Get(Config::NETPLAY_LISTEN_PORT) :
                                  Config::Get(Config::NETPLAY_HOST_PORT)) :
                     Config::Get(Config::NETPLAY_CONNECT_PORT);
  }

  Config::SetBase(Config::NETPLAY_NICKNAME, FoundationToCppString(nickname));
  Config::SetBase(Config::NETPLAY_TRAVERSAL_CHOICE, traversal ? std::string("traversal") :
                                                               std::string("direct"));
  if (hosting)
  {
    Config::SetBase(traversal ? Config::NETPLAY_LISTEN_PORT : Config::NETPLAY_HOST_PORT,
                    static_cast<u16>(port));
    Config::SetBase(Config::NETPLAY_USE_INDEX, _publicRoomSwitch.on);
    Config::SetBase(Config::NETPLAY_INDEX_NAME, FoundationToCppString(_roomNameField.text ?: @""));
    NSArray<NSString*>* regions = @[@"AF", @"EA", @"EU", @"NA", @"OC", @"SA", @"CN"];
    const NSInteger region_index = std::clamp((NSInteger)_regionControl.selectedSegmentIndex,
                                               NSInteger{0}, (NSInteger)regions.count - 1);
    Config::SetBase(Config::NETPLAY_INDEX_REGION,
                    FoundationToCppString(regions[region_index]));
    Config::SetBase(Config::NETPLAY_INDEX_PASSWORD,
                    FoundationToCppString(_roomPasswordField.text ?: @""));
  }
  else
  {
    Config::SetBase(Config::NETPLAY_CONNECT_PORT, static_cast<u16>(port));
    Config::SetBase(traversal ? Config::NETPLAY_HOST_CODE : Config::NETPLAY_ADDRESS,
                    FoundationToCppString(endpoint));
  }
  Config::Save();

  _connectButton.enabled = false;
  s_active_netplay_controller = self;
  _statusLabel.text = hosting ? @"Starting NetPlay host…" : @"Connecting to NetPlay…";
  _games = [self libraryGames];
  std::vector<std::shared_ptr<const UICommon::GameFile>> gameSharedPtrs;
  gameSharedPtrs.reserve(_games.count);
  for (GameFilePtrWrapper* wrapper in _games)
    gameSharedPtrs.push_back(wrapper.gameFile);

  std::vector<DOLGameFileHandle> gameHandles;
  gameHandles.reserve(gameSharedPtrs.size());
  for (const auto& game : gameSharedPtrs)
    gameHandles.push_back(&game);

  DOLNetPlayCallbacks callbacks = {};
  callbacks.context = (__bridge_retained void*)self;
  callbacks.on_event = NetPlayEvent;
  callbacks.on_boot_game = NetPlayBoot;
  _callbackContext = callbacks.context;
  _nativeSession = DOLNetPlayCreateWithGames(gameHandles.data(), gameHandles.size(), &callbacks);
  if (!_nativeSession)
  {
    if (_callbackContext)
      CFBridgingRelease(_callbackContext);
    _callbackContext = nullptr;
    s_active_netplay_controller = nil;
    _connectButton.enabled = true;
    [self netPlayError:@"Could not initialize NetPlay."];
    return;
  }

  const std::string address = FoundationToCppString(traversal && hosting ? @"" : endpoint);
  const std::string nick = FoundationToCppString(nickname);
  const std::string traversal_server = Config::Get(Config::NETPLAY_TRAVERSAL_SERVER);
  const u16 traversal_port = Config::Get(Config::NETPLAY_TRAVERSAL_PORT);
  const u16 traversal_port_alt = Config::Get(Config::NETPLAY_TRAVERSAL_PORT_ALT);
  const bool use_upnp = _upnpSwitch.on;
  Config::SetBase(Config::NETPLAY_USE_UPNP, self->_upnpSwitch.on);
  Config::Save();
  const NSUInteger port_value = static_cast<NSUInteger>(port);
  void* session = _nativeSession;
  _connectionInProgress = true;

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    const bool connected = DOLNetPlayConnect(session, hosting, traversal, address.c_str(),
                                              static_cast<uint16_t>(port_value), nick.c_str(),
                                              traversal_server.c_str(), traversal_port,
                                              traversal_port_alt, use_upnp);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (session != self->_nativeSession)
        return;
      self->_connectionInProgress = false;
      if (self->_closeRequested)
      {
        [self closeNativeSession];
        return;
      }
      self->_connectButton.enabled = true;
      if (!connected)
      {
        [self netPlayError:hosting ? @"Could not start or connect to the local NetPlay host. Check the selected port and try again." : @"Could not connect. Check the address, port, room code, and Dolphin version."];
        [self closeNativeSession];
        return;
      }
      self->_setupStack.hidden = true;
      self->_sessionStack.hidden = false;
      self->_startButton.hidden = !hosting;
      self->_shareJoinInfoButton.hidden = !hosting;
      self->_networkModeControl.hidden = !hosting;
      self->_serverBufferLabel.hidden = !hosting;
      self->_serverBufferControl.hidden = !hosting;
      for (UIButton* button in self->_mappingButtons)
        button.hidden = !hosting;
      self.navigationItem.title = @"NetPlay Session";
      self->_sessionStatusLabel.text = self->_statusLabel.text;
      if (!hosting || !traversal)
      {
        self->_statusLabel.text = @"Connected";
        self->_sessionStatusLabel.text = @"Connected";
      }
      if (hosting && !traversal)
      {
        const uint16_t host_port = DOLNetPlayGetPort(session);
        self->_statusLabel.text = [NSString stringWithFormat:@"Direct host, port %u", host_port];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
          char external_ip[64] = {};
          char local_ip[64] = {};
          const bool got_external = DOLNetPlayGetExternalIP(external_ip, sizeof(external_ip));
          const bool got_local = DOLNetPlayGetLocalIP(local_ip, sizeof(local_ip));
          NSMutableArray<NSString*>* addresses = [[NSMutableArray alloc] init];
          if (got_local)
            [addresses addObject:[NSString stringWithFormat:@"Local address: %s:%u", local_ip, host_port]];
          if (got_external)
            [addresses addObject:[NSString stringWithFormat:@"External address: %s:%u", external_ip, host_port]];
          NSString* address = addresses.count ? [addresses componentsJoinedByString:@"\n"] :
                                                [NSString stringWithFormat:@"Direct host, port %u", host_port];
          dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_nativeSession == session)
            {
              self->_statusLabel.text = address;
              self->_sessionStatusLabel.text = address;
            }
          });
        });
      }
      if (hosting)
        [self updateSessionGameState];
      [self updateControllerMappings];
    });
  });
}

- (void)shareJoinInfo
{
  if (_sessionStatusLabel.text.length == 0)
    return;
  UIActivityViewController* activity = [[UIActivityViewController alloc]
      initWithActivityItems:@[_sessionStatusLabel.text]
      applicationActivities:nil];
  activity.popoverPresentationController.sourceView = _shareJoinInfoButton;
  activity.popoverPresentationController.sourceRect = _shareJoinInfoButton.bounds;
  [self presentViewController:activity animated:true completion:nil];
}

- (void)setSelectedGame:(GameFilePtrWrapper*)wrapper
{
  if (!wrapper)
    return;

  _selectedGame = wrapper;
  [self updateSetupGameButton];
  if (!_nativeSession)
    return;

  const std::string path = wrapper.gameFile->GetFilePath();
  NSString* title =
      ToNSString(wrapper.gameFile->GetName(UICommon::GameFile::Variant::LongAndPossiblyCustom));
  if (!DOLNetPlaySetGame(_nativeSession, path.c_str()))
  {
    _gameLabel.textColor = UIColor.systemRedColor;
    _gameLabel.text = [NSString stringWithFormat:@"Could not select %@ for this session.", title];
    return;
  }
  _gameLabel.textColor = UIColor.labelColor;
  _gameLabel.text = [NSString stringWithFormat:@"Game: %@", title];
  [_changeGameButton setTitle:@"Change game" forState:UIControlStateNormal];
}

- (void)updateSetupGameButton
{
  NSString* title;
  if (_selectedGame)
  {
    title = [NSString
        stringWithFormat:@"Game: %@",
                         ToNSString(_selectedGame.gameFile->GetName(
                             UICommon::GameFile::Variant::LongAndPossiblyCustom))];
  }
  else
  {
    title = @"Game: none selected — tap to choose the game to host";
  }
  [_setupGameButton setTitle:title forState:UIControlStateNormal];
}

- (NSArray<GameFilePtrWrapper*>*)libraryGames
{
  if (_games.count == 0)
  {
    // The cache can still be empty when NetPlay is opened straight from the
    // software list, which would otherwise leave the host with nothing to pick.
    [[GameFileCacheManager sharedManager] rescan];
    _games = [[GameFileCacheManager sharedManager] getGames];
  }
  return _games;
}

- (void)selectGame
{
  if (_roleControl.selectedSegmentIndex != 1)
    return;

  NSArray<GameFilePtrWrapper*>* games = [self libraryGames];
  if (games.count == 0)
  {
    [self netPlayError:@"No games were found in your library. Add a game, then try hosting again."];
    return;
  }

  NetPlayGamePickerViewController* picker =
      [[NetPlayGamePickerViewController alloc] initWithGames:games selectedGame:_selectedGame];
  picker.pickerDelegate = self;
  UINavigationController* navigationController =
      [[UINavigationController alloc] initWithRootViewController:picker];
  navigationController.modalPresentationStyle = UIModalPresentationFormSheet;
  [self presentViewController:navigationController animated:true completion:nil];
}

- (void)gamePicker:(NetPlayGamePickerViewController*)picker
    didSelectGame:(GameFilePtrWrapper*)game
{
  [picker dismissViewControllerAnimated:true completion:nil];
  [self setSelectedGame:game];
}

- (void)updateSessionGameState
{
  if (_selectedGame)
  {
    [self setSelectedGame:_selectedGame];
    return;
  }

  _gameLabel.textColor = UIColor.secondaryLabelColor;
  _gameLabel.text =
      _games.count == 0 ? @"No game selected, and no games were found in your library." :
                          @"No game selected yet. Tap “Select game” so players know what to load.";
}

- (UIStepper*)bufferStepperWithValue:(u32)value action:(SEL)action
{
  UIStepper* stepper = [[UIStepper alloc] init];
  stepper.minimumValue = 0;
  stepper.maximumValue = 30;
  stepper.stepValue = 1;
  stepper.value = value;
  [stepper addTarget:self action:action forControlEvents:UIControlEventValueChanged];
  return stepper;
}

- (void)updateBufferLabels
{
  _serverBufferLabel.text = [NSString stringWithFormat:@"Host pad buffer: %d", (int)_serverBufferControl.value];
  _clientBufferLabel.text = [NSString stringWithFormat:@"Client pad buffer: %d", (int)_clientBufferControl.value];
}

- (void)networkModeChanged
{
  static const char* modes[] = {"fixeddelay", "hostinputauthority"};
  const int index = std::clamp((int)_networkModeControl.selectedSegmentIndex, 0, 1);
  Config::SetBase(Config::NETPLAY_NETWORK_MODE, std::string(modes[index]));
  Config::Save();
  DOLNetPlaySetHostInputAuthority(_nativeSession, index != 0);
}

- (void)serverBufferChanged
{
  Config::SetBase(Config::NETPLAY_BUFFER_SIZE, static_cast<u32>(_serverBufferControl.value));
  Config::Save();
  DOLNetPlayAdjustPadBuffer(_nativeSession, static_cast<int>(_serverBufferControl.value), false);
  [self updateBufferLabels];
}

- (void)clientBufferChanged
{
  Config::SetBase(Config::NETPLAY_CLIENT_BUFFER_SIZE, static_cast<u32>(_clientBufferControl.value));
  Config::Save();
  DOLNetPlayAdjustPadBuffer(_nativeSession, static_cast<int>(_clientBufferControl.value), true);
  [self updateBufferLabels];
}

- (void)browseSessions
{
  _statusLabel.text = @"Loading public sessions…";
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    std::vector<ListedSession> sessions;
    const bool success = DOLNetPlayBrowse(CollectSession, &sessions);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!success)
      {
        self->_statusLabel.text = @"Could not load public sessions.";
        [self netPlayError:@"The Dolphin lobby could not be reached. Check your internet connection and try again."];
        return;
      }
      self->_listedSessions = std::move(sessions);
      if (self->_listedSessions.empty())
      {
        self->_statusLabel.text = @"No public sessions are listed right now.";
        return;
      }
      UIAlertController* picker = [UIAlertController alertControllerWithTitle:@"Public NetPlay Sessions"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
      for (NSUInteger i = 0; i < self->_listedSessions.size(); ++i)
      {
        const ListedSession& session = self->_listedSessions[i];
        NSString* title = [NSString stringWithFormat:@"%@ · %@ · %d player%@%@",
                                                     ToNSString(session.name), ToNSString(session.region),
                                                     session.player_count,
                                                     session.player_count == 1 ? @"" : @"s",
                                                     session.in_game ? @" · In game" : @""];
        [picker addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
          [self joinListedSessionAtIndex:i password:nil];
        }]];
      }
      [picker addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
      picker.popoverPresentationController.sourceView = self.view;
      picker.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2,
                                                                     self.view.bounds.size.height / 2, 1, 1);
      [self presentViewController:picker animated:true completion:nil];
    });
  });
}

- (void)joinListedSessionAtIndex:(NSUInteger)index password:(NSString*)password
{
  if (index >= _listedSessions.size())
    return;
  const ListedSession& session = _listedSessions[index];
  std::string server_id = session.server_id;
  if (session.has_password)
  {
    if (!password)
    {
      UIAlertController* prompt = [UIAlertController alertControllerWithTitle:@"Session Password"
                                                                        message:@"Enter the password for this room."
                                                                 preferredStyle:UIAlertControllerStyleAlert];
      [prompt addTextFieldWithConfigurationHandler:^(UITextField* field) { field.secureTextEntry = true; }];
      [prompt addAction:[UIAlertAction actionWithTitle:@"Join" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
        [self joinListedSessionAtIndex:index password:prompt.textFields.firstObject.text ?: @""];
      }]];
      [prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
      [self presentViewController:prompt animated:true completion:nil];
      return;
    }
    char decoded[256] = {};
    if (!DOLNetPlayDecryptSessionId(server_id.c_str(), FoundationToCppString(password).c_str(),
                                    decoded, sizeof(decoded)))
    {
      [self netPlayError:@"That password is incorrect."];
      return;
    }
    server_id = decoded;
    Config::SetBase(Config::NETPLAY_INDEX_PASSWORD, FoundationToCppString(password));
  }
  _roleControl.selectedSegmentIndex = 0;
  _connectionControl.selectedSegmentIndex = session.method == "traversal" ? 1 : 0;
  _addressField.text = ToNSString(server_id);
  _portField.text = [NSString stringWithFormat:@"%d", session.port];
  Config::SetBase(Config::NETPLAY_TRAVERSAL_CHOICE, session.method);
  Config::SetBase(Config::NETPLAY_CONNECT_PORT, static_cast<u16>(session.port));
  Config::SetBase(session.method == "traversal" ? Config::NETPLAY_HOST_CODE : Config::NETPLAY_ADDRESS,
                  server_id);
  [self connectTapped];
}

- (void)startGame
{
  if (!_nativeSession)
    return;
  if (!DOLNetPlayHasGameSelected(_nativeSession))
  {
    [self netPlayError:@"Please select a game before starting NetPlay."];
    return;
  }
  if (!DOLNetPlayIsSelectedGameAvailable(_nativeSession))
  {
    [self netPlayError:@"The selected game file is not available in your local library."];
    return;
  }
  if (!DOLNetPlayDoAllPlayersHaveGame(_nativeSession))
  {
    [self netPlayError:@"At least one player does not have the selected game. Ask everyone to add the matching game file to their library."];
    return;
  }
  if (Config::Get(Config::MAIN_CPU_THREAD))
  {
    UIAlertController* warning = [UIAlertController
        alertControllerWithTitle:@"Dual Core Warning"
                         message:@"Dual Core can cause NetPlay desyncs. Continue with the current setting, or turn it off before starting."
                  preferredStyle:UIAlertControllerStyleAlert];
    [warning addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [warning addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
      DOLNetPlayStartGame(self->_nativeSession);
    }]];
    [warning addAction:[UIAlertAction actionWithTitle:@"Turn Off Dual Core" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
      Config::SetBase(Config::MAIN_CPU_THREAD, false);
      Config::Save();
      DOLNetPlayStartGame(self->_nativeSession);
    }]];
    [self presentViewController:warning animated:true completion:nil];
    return;
  }
  DOLNetPlayStartGame(_nativeSession);
}

- (void)sendChat
{
  NSString* text = [_chatField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!_nativeSession || text.length == 0)
    return;
  const std::string message = FoundationToCppString(text);
  DOLNetPlaySendChat(_nativeSession, message.c_str());
  _chatField.text = @"";
}

- (BOOL)textFieldShouldReturn:(UITextField*)textField
{
  if (textField == _chatField)
  {
    [self sendChat];
  }
  else
  {
    [textField resignFirstResponder];
  }
  return YES;
}

- (void)closeSession
{
  if (Core::IsRunning(Core::System::GetInstance()))
  {
    [self netPlayError:@"Stop the game before leaving NetPlay so the session can shut down cleanly."];
    return;
  }
  [self closeNativeSession];
  [self dismissViewControllerAnimated:true completion:nil];
}

- (void)closeNativeSession
{
  if (_connectionInProgress)
  {
    // DOLNetPlayConnect is using this pointer on a worker thread. Defer its
    // destruction until that call has returned to the main queue.
    _closeRequested = true;
    return;
  }

  void* session = _nativeSession;
  void* context = _callbackContext;
  _nativeSession = nullptr;
  _callbackContext = nullptr;
  _closeRequested = false;
  _connectionLostPending = false;
  _pendingTraversalFatalError = nil;
  if (s_active_netplay_controller == self)
    s_active_netplay_controller = nil;
  _sessionStack.hidden = true;
  _setupStack.hidden = false;
  _statusLabel.text = @"Disconnected";
  [_changeGameButton setTitle:@"Select game" forState:UIControlStateNormal];
  if (!session)
    return;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    DOLNetPlayClose(session);
    if (context)
      CFBridgingRelease(context);
  });
}

- (void)emulationEnded
{
  if (!_nativeSession)
    return;
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.delegate netPlayViewControllerDidRequestSessionScreen:self];
  });
}

- (void)handleNetPlayEvent:(int)event message:(NSString*)message
{
  switch (event)
  {
  case DOLNetPlayEventPlayers:
    _playersLabel.text = message;
    [self updateControllerMappings];
    break;
  case DOLNetPlayEventChat:
    _chatView.text = _chatView.text.length ? [_chatView.text stringByAppendingFormat:@"\n%@", message] : message;
    [_chatView scrollRangeToVisible:NSMakeRange(_chatView.text.length, 0)];
    break;
  case DOLNetPlayEventGame: {
    NSString* problem = nil;
    switch (DOLNetPlayGetSelectedGameComparison(_nativeSession))
    {
    case DOLNetPlayGameComparisonSameGame:
      break;
    case DOLNetPlayGameComparisonDifferentHash:
      problem = @"your game data does not match the host's";
      break;
    case DOLNetPlayGameComparisonDifferentDiscNumber:
      problem = @"different disc";
      break;
    case DOLNetPlayGameComparisonDifferentRevision:
      problem = @"different game revision";
      break;
    case DOLNetPlayGameComparisonDifferentRegion:
      problem = @"different region";
      break;
    case DOLNetPlayGameComparisonDifferentGame:
    case DOLNetPlayGameComparisonUnknown:
      problem = @"not found in your library";
      break;
    }

    if (problem)
    {
      _gameLabel.text =
          [NSString stringWithFormat:@"Game: %@ (%@!)", message, problem];
      _gameLabel.textColor = UIColor.systemRedColor;
    }
    else
    {
      _gameLabel.text = [NSString stringWithFormat:@"Game: %@", message];
      _gameLabel.textColor = UIColor.labelColor;
    }
    break;
  }
  case DOLNetPlayEventStatus:
  case DOLNetPlayEventIndex:
    _statusLabel.text = message;
    _sessionStatusLabel.text = message;
    break;
  case DOLNetPlayEventError:
    [self netPlayError:message];
    break;
  case DOLNetPlayEventConnectionLost:
    _connectionLostPending = true;
    [self presentConnectionLostAlertIfNeeded];
    break;
  case DOLNetPlayEventTraversalRetryableError:
    _statusLabel.text = message;
    _sessionStatusLabel.text = message;
    _retryTraversalButton.hidden = false;
    break;
  case DOLNetPlayEventTraversalFatalError:
    _statusLabel.text = message;
    _sessionStatusLabel.text = message;
    _retryTraversalButton.hidden = true;
    _pendingTraversalFatalError = message;
    [self presentTraversalFatalErrorIfNeeded];
    break;
  case DOLNetPlayEventTraversalConnected:
    _statusLabel.text = message;
    _sessionStatusLabel.text = message;
    _retryTraversalButton.hidden = true;
    break;
  case DOLNetPlayEventStartGame:
    // DOLNetPlayStartClientGame validates the local game and reports a precise
    // error (missing file, different region/revision/hash) before booting.
    if (_nativeSession)
      DOLNetPlayStartClientGame(_nativeSession);
    break;
  case DOLNetPlayEventPowerButton:
    if (_nativeSession)
      DOLNetPlayTriggerPowerButton(_nativeSession);
    break;
  }
}

- (void)presentConnectionLostAlertIfNeeded
{
  if (!_connectionLostPending || !self.isViewLoaded || !self.view.window ||
      self.presentedViewController)
  {
    return;
  }

  _connectionLostPending = false;
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:@"NetPlay connection lost"
                       message:@"The connection to the host was lost. The NetPlay session will close."
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
    if (Core::IsRunning(Core::System::GetInstance()))
    {
      self->_connectionLostPending = true;
      [self closeSession];
      return;
    }
    [self closeNativeSession];
    [self dismissViewControllerAnimated:true completion:nil];
  }]];
  [self presentViewController:alert animated:true completion:nil];
}

- (void)presentTraversalFatalErrorIfNeeded
{
  if (!_pendingTraversalFatalError || !self.isViewLoaded || !self.view.window ||
      self.presentedViewController)
  {
    return;
  }

  NSString* message = _pendingTraversalFatalError;
  _pendingTraversalFatalError = nil;
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:@"Traversal error"
                       message:message
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"Close NetPlay"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction*) {
                                            if (Core::IsRunning(Core::System::GetInstance()))
                                            {
                                              self->_pendingTraversalFatalError = message;
                                              [self closeSession];
                                              return;
                                            }
                                            [self closeNativeSession];
                                            [self dismissViewControllerAnimated:true
                                                                     completion:nil];
                                          }]];
  [self presentViewController:alert animated:true completion:nil];
}

- (void)retryTraversalTapped
{
  if (!_nativeSession)
    return;

  _retryTraversalButton.hidden = true;
  _sessionStatusLabel.text = @"Reconnecting to the traversal server…";
  if (!DOLNetPlayRetryTraversal(_nativeSession))
  {
    _retryTraversalButton.hidden = false;
    _sessionStatusLabel.text = @"Could not retry the traversal connection.";
  }
}

- (void)updateControllerMappings
{
  if (!_nativeSession)
    return;
  uint8_t gamecube[4] = {};
  uint8_t wiimotes[4] = {};
  if (!DOLNetPlayGetControllerMappings(_nativeSession, gamecube, 4, wiimotes, 4))
    return;
  DOLNetPlayPlayerInfo players[255] = {};
  const size_t player_count = DOLNetPlayGetPlayers(_nativeSession, players, 255);
  for (NSInteger index = 0; index < 8; ++index)
  {
    const bool wiimote = index >= 4;
    const size_t port = static_cast<size_t>(index % 4);
    const uint8_t player_id = wiimote ? wiimotes[port] : gamecube[port];
    NSString* player_name = @"Unassigned";
    for (size_t i = 0; i < std::min(player_count, static_cast<size_t>(255)); ++i)
    {
      if (players[i].id == player_id && player_id != 0)
      {
        player_name = [NSString stringWithUTF8String:players[i].name];
        break;
      }
    }
    NSString* kind = wiimote ? @"Wii Remote" : @"GameCube controller";
    [_mappingButtons[index] setTitle:[NSString stringWithFormat:@"%@ %zu: %@", kind, port + 1,
                                                                  player_name]
                            forState:UIControlStateNormal];
  }
}

- (void)controllerMappingTapped:(UIButton*)sender
{
  if (!_nativeSession || _roleControl.selectedSegmentIndex != 1)
    return;
  DOLNetPlayPlayerInfo players[255] = {};
  const size_t player_count = std::min(DOLNetPlayGetPlayers(_nativeSession, players, 255),
                                       static_cast<size_t>(255));
  const bool wiimote = sender.tag >= 4;
  const int port = static_cast<int>(sender.tag % 4);
  UIAlertController* picker = [UIAlertController alertControllerWithTitle:sender.titleLabel.text
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
  [picker addAction:[UIAlertAction actionWithTitle:@"Unassigned" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
    DOLNetPlaySetControllerMapping(self->_nativeSession, wiimote, port, 0);
    [self updateControllerMappings];
  }]];
  for (size_t i = 0; i < player_count; ++i)
  {
    const uint8_t player_id = players[i].id;
    NSString* name = [NSString stringWithUTF8String:players[i].name];
    [picker addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
      DOLNetPlaySetControllerMapping(self->_nativeSession, wiimote, port, player_id);
      [self updateControllerMappings];
    }]];
  }
  [picker addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  picker.popoverPresentationController.sourceView = sender;
  picker.popoverPresentationController.sourceRect = sender.bounds;
  [self presentViewController:picker animated:true completion:nil];
}

- (BOOL)netPlayBootGame:(NSString*)path sessionData:(BootSessionData*)sessionData
{
  if (_closeRequested || !_nativeSession)
  {
    return NO;
  }

  const std::string boot_path = FoundationToCppString(path);
  if (path.length == 0 || !File::Exists(boot_path))
  {
    [self netPlayError:@"The game file could not be found on disk to boot NetPlay."];
    return NO;
  }

  EmulationBootParameter* parameter = [[EmulationBootParameter alloc] init];
  parameter.bootType = EmulationBootTypeFile;
  parameter.path = path;
  parameter.netplayBootSessionData = sessionData;
  parameter.isNKit = false;
  for (GameFilePtrWrapper* wrapper in _games)
  {
    if (wrapper.gameFile->GetFilePath() == boot_path)
    {
      parameter.isNKit = wrapper.gameFile->IsNKit();
      break;
    }
  }
  [self.delegate netPlayViewController:self didRequestGameLaunch:parameter];
  return YES;
}

- (void)netPlayError:(NSString*)message
{
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"NetPlay"
                                                                 message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];

  // The session screen is hidden while a game is running, so fall back to the
  // topmost controller (the emulation view) to keep desync and error alerts visible.
  UIViewController* presenter = self.view.window ? self : DOLTopViewController();
  if (!presenter || presenter.presentedViewController)
    return;

  [presenter presentViewController:alert animated:true completion:nil];
}

@end
