//
//  SettingsPageViewController.m
//  zxtouch
//
//  Created by Jason on 2021/1/18.
//

#import "SettingsPageViewController.h"
#import "ScriptListTableCell.h"
#import "TouchIndicatorConfigurationViewController.h"
#import "Util.h"
#import "Socket.h"

#import "TableViewCellWithSwitch.h"
#import "TableViewCellWithSlider.h"
#import "TableViewCellWithEntry.h"

#import "GCDWebServer.h"
#import "GCDWebServerDataResponse.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import "Config.h"
#import "ConfigManager.h"
#import "RemoteDashboardServer.h"

#define SETTING_CELL_SWITCH 0
#define SETTING_CELL_ENTRY 1

#define ZX_ACTION_SMART_TOGGLE @"smart_toggle"
#define ZX_ACTION_TOGGLE_PANEL @"toggle_panel"
#define ZX_ACTION_STOP_SCRIPT @"stop_script"
#define ZX_ACTION_TOGGLE_RECORDING @"toggle_recording"
#define ZX_ACTION_RUN_SCRIPT @"run_script"

#define ZX_TRIGGER_VOLUME_UP @"volume_up"
#define ZX_TRIGGER_VOLUME_DOWN @"volume_down"
#define ZX_TRIGGER_HOME @"home"

static UIImage *ZXSettingsSymbol(NSString *name) {
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:name];
    }
    return nil;
}

@interface SettingsPageViewController ()
{
    GCDWebServer* _webServer;
}
@end

@implementation SettingsPageViewController
{
    NSArray *sections;
    NSArray<NSArray*> *cellsForEachSection;
    ConfigManager *configManager;
}

- (BOOL)darkModeEnabled {
    id configValue = [configManager getValueFromKey:@"dark_mode"];
    if (configValue) {
        return [configValue boolValue];
    }
    BOOL legacyValue = [[NSUserDefaults standardUserDefaults] boolForKey:@"dark_mode"];
    [configManager updateKey:@"dark_mode" forValue:@(legacyValue)];
    [configManager save];
    return legacyValue;
}

- (NSString *)triggerActionTitle:(NSString *)action {
    if ([action isEqualToString:ZX_ACTION_TOGGLE_PANEL]) return @"Toggle Panel";
    if ([action isEqualToString:ZX_ACTION_STOP_SCRIPT]) return @"Stop Script";
    if ([action isEqualToString:ZX_ACTION_TOGGLE_RECORDING]) return @"Toggle Recording";
    if ([action isEqualToString:ZX_ACTION_RUN_SCRIPT]) return @"Run Default Script";
    return @"Smart Toggle";
}

- (NSString *)triggerTitle:(NSString *)triggerKey {
    if ([triggerKey isEqualToString:ZX_TRIGGER_VOLUME_UP]) return @"Volume Up";
    if ([triggerKey isEqualToString:ZX_TRIGGER_HOME]) return @"Home Button";
    return @"Volume Down";
}

- (NSMutableDictionary *)triggerConfigForKey:(NSString *)triggerKey {
    NSMutableDictionary *allTriggers = [[configManager getValueFromKey:@"trigger_configs"] mutableCopy];
    NSDictionary *existing = [allTriggers isKindOfClass:[NSDictionary class]] ? allTriggers[triggerKey] : nil;
    if ([existing isKindOfClass:[NSDictionary class]]) return [existing mutableCopy];

    if ([triggerKey isEqualToString:ZX_TRIGGER_VOLUME_DOWN]) {
        BOOL enabled = YES;
        if ([configManager getValueFromKey:@"double_click_volume_show_popup"])
            enabled = [[configManager getValueFromKey:@"double_click_volume_show_popup"] boolValue];
        return [@{
            @"enabled": @(enabled),
            @"count": @(2),
            @"action": [configManager getValueFromKey:@"double_click_volume_action"] ?: ZX_ACTION_SMART_TOGGLE,
            @"script": [configManager getValueFromKey:@"double_click_volume_script"] ?: @""
        } mutableCopy];
    }

    return [@{@"enabled": @(NO), @"count": @(2), @"action": ZX_ACTION_SMART_TOGGLE, @"script": @""} mutableCopy];
}

- (void)saveTriggerConfig:(NSMutableDictionary *)trigger forKey:(NSString *)triggerKey {
    NSMutableDictionary *allTriggers = [[configManager getValueFromKey:@"trigger_configs"] mutableCopy];
    if (![allTriggers isKindOfClass:[NSMutableDictionary class]]) allTriggers = [NSMutableDictionary dictionary];
    allTriggers[triggerKey] = trigger;
    [configManager updateKey:@"trigger_configs" forValue:allTriggers];

    if ([triggerKey isEqualToString:ZX_TRIGGER_VOLUME_DOWN]) {
        [configManager updateKey:@"double_click_volume_show_popup" forValue:trigger[@"enabled"]];
        [configManager updateKey:@"double_click_volume_action" forValue:trigger[@"action"]];
        [configManager updateKey:@"double_click_volume_script" forValue:trigger[@"script"]];
    }
    [configManager save];
    [self reloadSettingsModel];
}

- (NSString *)triggerSummaryForKey:(NSString *)triggerKey {
    NSDictionary *trigger = [self triggerConfigForKey:triggerKey];
    if (![trigger[@"enabled"] boolValue]) return @"Off";
    NSString *clickWord = [trigger[@"count"] intValue] == 1 ? @"click" : @"clicks";
    NSString *actionTitle = [self triggerActionTitle:trigger[@"action"]];
    NSString *script = trigger[@"script"];
    if ([trigger[@"action"] isEqualToString:ZX_ACTION_RUN_SCRIPT] && [script length] > 0) {
        actionTitle = [NSString stringWithFormat:@"Run %@", [[script lastPathComponent] stringByDeletingPathExtension]];
    }
    return [NSString stringWithFormat:@"%@ %@ -> %@", trigger[@"count"], clickWord, actionTitle];
}

- (NSArray<NSString *> *)availableScriptPaths {
    NSMutableArray *paths = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:SCRIPTS_PATH];
    NSString *relative = nil;
    while ((relative = [enumerator nextObject])) {
        if ([[relative pathExtension] isEqualToString:@"bdl"]) {
            [paths addObject:[SCRIPTS_PATH stringByAppendingPathComponent:relative]];
            [enumerator skipDescendants];
        }
    }
    return [paths sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (NSString *)iconNameForCellTitle:(NSString *)title {
    if ([title containsString:@"Web"]) return @"globe";
    if ([title containsString:@"Touch"]) return @"hand.tap";
    if ([title containsString:@"Double-click"]) return @"bolt.badge.clock";
    if ([title containsString:@"Volume"]) return @"speaker.wave.2";
    if ([title containsString:@"Default Trigger"]) return @"play.square.stack";
    if ([title containsString:@"Switch App"]) return @"arrow.triangle.2.circlepath";
    if ([title containsString:@"Example"]) return @"folder";
    if ([title containsString:@"Registry"]) return @"list.bullet.rectangle";
    if ([title containsString:@"Dark"]) return @"moon";
    if ([title containsString:@"ZXTouch"]) return @"info.circle";
    return @"gearshape";
}

- (NSArray<NSDictionary *> *)remoteManagementCells {
    BOOL enabled = ZXRemoteDashboardIsEnabled();
    NSMutableArray *cells = [NSMutableArray arrayWithObject:@{
        @"type": @(SETTING_CELL_SWITCH),
        @"title": NSLocalizedString(@"webServer", nil),
        @"switch_click_handler": NSStringFromSelector(@selector(handleWebServerWithSwitchCellInstance:)),
        @"switch_init_status": @(enabled)
    }];
    if (enabled) {
        [cells addObject:@{
            @"type": @(SETTING_CELL_ENTRY),
            @"title": @"Dashboard URL",
            @"secondary_title": @"Tap to view and copy",
            @"row_click_handler": NSStringFromSelector(@selector(handleDashboardURLTap:))
        }];
    }
    return cells;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    self.title = @"Settings";
    
    sections = @[NSLocalizedString(@"remoteManagement", nil), NSLocalizedString(@"control", nil), @"Automation", NSLocalizedString(@"script", nil), @"Appearance", @"About"];
    configManager = [[ConfigManager alloc] initWithPath:SPRINGBOARD_CONFIG_PATH];
    BOOL doubleClickPopup = YES;
    if ([configManager getValueFromKey:@"double_click_volume_show_popup"])
    {
        doubleClickPopup = [[configManager getValueFromKey:@"double_click_volume_show_popup"] boolValue];
    }
    
    BOOL switchAppBeforeRunScript = YES;
    if ([configManager getValueFromKey:@"switch_app_before_run_script"])
    {
        switchAppBeforeRunScript = [[configManager getValueFromKey:@"switch_app_before_run_script"] boolValue];
    }

    BOOL showFinishedPopup = YES;
    if ([configManager getValueFromKey:@"show_script_finished_popup"])
    {
        showFinishedPopup = [[configManager getValueFromKey:@"show_script_finished_popup"] boolValue];
    }

    BOOL darkMode = [self darkModeEnabled];

    // [@{"type": ?, @"title": ?, @"content": ?, ... more depends on the cell type}]
    //
    cellsForEachSection = @[
        [self remoteManagementCells],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": NSLocalizedString(@"touchIndicator", nil), @"secondary_title": @"", @"row_click_handler": NSStringFromSelector(@selector(handleTouchIndicatorWithEntryCellInstance:))},
            @{@"type": @(SETTING_CELL_SWITCH), @"title": NSLocalizedString(@"doubleClickShowPopup", nil), @"switch_click_handler": NSStringFromSelector(@selector(handlePopupWindowDoubleClick:)), @"switch_init_status": @(doubleClickPopup)}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"Volume Up", @"secondary_title": [self triggerSummaryForKey:ZX_TRIGGER_VOLUME_UP], @"trigger_key": ZX_TRIGGER_VOLUME_UP, @"row_click_handler": NSStringFromSelector(@selector(handleTriggerTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"Volume Down", @"secondary_title": [self triggerSummaryForKey:ZX_TRIGGER_VOLUME_DOWN], @"trigger_key": ZX_TRIGGER_VOLUME_DOWN, @"row_click_handler": NSStringFromSelector(@selector(handleTriggerTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"Home Button", @"secondary_title": [self triggerSummaryForKey:ZX_TRIGGER_HOME], @"trigger_key": ZX_TRIGGER_HOME, @"row_click_handler": NSStringFromSelector(@selector(handleTriggerTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_SWITCH), @"title": NSLocalizedString(@"switchAppBeforePlaying", nil), @"switch_click_handler": NSStringFromSelector(@selector(handleSwitchAppBeforePlaying:)), @"switch_init_status": @(switchAppBeforeRunScript)},
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"Script Finished Popup", @"switch_click_handler": NSStringFromSelector(@selector(handleScriptFinishedPopupToggle:)), @"switch_init_status": @(showFinishedPopup)},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"Example Scripts", @"secondary_title": EXAMPLE_SCRIPTS_PATH, @"row_click_handler": NSStringFromSelector(@selector(handleExamplesTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"Script Registry", @"secondary_title": SCRIPT_REGISTRY_PATH, @"row_click_handler": NSStringFromSelector(@selector(handleRegistryTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"Dark Mode", @"switch_click_handler": NSStringFromSelector(@selector(handleDarkModeToggle:)), @"switch_init_status": @(darkMode)}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"ZXTouch Rootless 0.1.8", @"secondary_title": @"iOS 15-17 port by Epic0001", @"row_click_handler": NSStringFromSelector(@selector(handleCreditsTap:))}
        ]
    ];
     
    UINib *SwitchCellNib = [UINib nibWithNibName:@"TableViewCellWithSwitch" bundle:nil];
    [_tableView registerNib:SwitchCellNib forCellReuseIdentifier:@"SwitchCell"];

    UINib *entryCellNib = [UINib nibWithNibName:@"TableViewCellWithEntry" bundle:nil];
    [_tableView registerNib:entryCellNib forCellReuseIdentifier:@"EntryCell"];
    
    _tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    _tableView.tableFooterView = [[UIView alloc] init];
    _tableView.rowHeight = 54;
    _tableView.separatorInset = UIEdgeInsetsMake(0, 52, 0, 0);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (configManager) {
        [self reloadSettingsModel];
    }
}

- (void)reloadSettingsModel {
    configManager = [[ConfigManager alloc] initWithPath:SPRINGBOARD_CONFIG_PATH];
    BOOL doubleClickPopup = YES;
    if ([configManager getValueFromKey:@"double_click_volume_show_popup"])
        doubleClickPopup = [[configManager getValueFromKey:@"double_click_volume_show_popup"] boolValue];
    BOOL switchAppBeforeRunScript = YES;
    if ([configManager getValueFromKey:@"switch_app_before_run_script"])
        switchAppBeforeRunScript = [[configManager getValueFromKey:@"switch_app_before_run_script"] boolValue];
    BOOL showFinishedPopup = YES;
    if ([configManager getValueFromKey:@"show_script_finished_popup"])
    {
        showFinishedPopup = [[configManager getValueFromKey:@"show_script_finished_popup"] boolValue];
    }

    BOOL darkMode = [self darkModeEnabled];

    sections = @[NSLocalizedString(@"remoteManagement", nil), NSLocalizedString(@"control", nil), @"Automation", NSLocalizedString(@"script", nil), @"Appearance", @"About"];
    cellsForEachSection = @[
        [self remoteManagementCells],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": NSLocalizedString(@"touchIndicator", nil), @"secondary_title": @"", @"row_click_handler": NSStringFromSelector(@selector(handleTouchIndicatorWithEntryCellInstance:))},
            @{@"type": @(SETTING_CELL_SWITCH), @"title": NSLocalizedString(@"doubleClickShowPopup", nil), @"switch_click_handler": NSStringFromSelector(@selector(handlePopupWindowDoubleClick:)), @"switch_init_status": @(doubleClickPopup)}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"Volume Up", @"secondary_title": [self triggerSummaryForKey:ZX_TRIGGER_VOLUME_UP], @"trigger_key": ZX_TRIGGER_VOLUME_UP, @"row_click_handler": NSStringFromSelector(@selector(handleTriggerTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"Volume Down", @"secondary_title": [self triggerSummaryForKey:ZX_TRIGGER_VOLUME_DOWN], @"trigger_key": ZX_TRIGGER_VOLUME_DOWN, @"row_click_handler": NSStringFromSelector(@selector(handleTriggerTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"Home Button", @"secondary_title": [self triggerSummaryForKey:ZX_TRIGGER_HOME], @"trigger_key": ZX_TRIGGER_HOME, @"row_click_handler": NSStringFromSelector(@selector(handleTriggerTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_SWITCH), @"title": NSLocalizedString(@"switchAppBeforePlaying", nil), @"switch_click_handler": NSStringFromSelector(@selector(handleSwitchAppBeforePlaying:)), @"switch_init_status": @(switchAppBeforeRunScript)},
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"Script Finished Popup", @"switch_click_handler": NSStringFromSelector(@selector(handleScriptFinishedPopupToggle:)), @"switch_init_status": @(showFinishedPopup)},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"Example Scripts", @"secondary_title": EXAMPLE_SCRIPTS_PATH, @"row_click_handler": NSStringFromSelector(@selector(handleExamplesTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"Script Registry", @"secondary_title": SCRIPT_REGISTRY_PATH, @"row_click_handler": NSStringFromSelector(@selector(handleRegistryTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"Dark Mode", @"switch_click_handler": NSStringFromSelector(@selector(handleDarkModeToggle:)), @"switch_init_status": @(darkMode)}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"ZXTouch Rootless 0.1.8", @"secondary_title": @"iOS 15-17 port by Epic0001", @"row_click_handler": NSStringFromSelector(@selector(handleCreditsTap:))}
        ]
    ];
    [_tableView reloadData];
}

- (void)handleSwitchAppBeforePlaying:(UISwitch*)s {
    if ([s isOn])
    {
        [configManager updateKey:@"switch_app_before_run_script" forValue:@(true)];
        [configManager save];
    }
    else
    {
        [configManager updateKey:@"switch_app_before_run_script" forValue:@(false)];
        [configManager save];
    }
    
    Socket *socket = [[Socket alloc] init];
    [socket connect:@"127.0.0.1" byPort:6000];
    [socket send:@"902"];
    [socket recv:1024];
    [socket close];
}

- (void)handleScriptFinishedPopupToggle:(UISwitch*)s {
    // Controls the "Script Finished" popup the tweak shows when a script ends.
    // Stored in the SpringBoard config so Play.xm can read it; defaults to on so
    // existing installs keep their current behaviour.
    [configManager updateKey:@"show_script_finished_popup" forValue:@([s isOn])];
    [configManager save];
}

- (void)handlePopupWindowDoubleClick:(UISwitch*)s {
    if ([s isOn])
    {
        [configManager updateKey:@"double_click_volume_show_popup" forValue:@(true)];
        [configManager save];
    }
    else
    {
        [configManager updateKey:@"double_click_volume_show_popup" forValue:@(false)];
        [configManager save];
    }
    Socket *socket = [[Socket alloc] init];
    [socket connect:@"127.0.0.1" byPort:6000];
    [socket send:@"901"];
    [socket recv:1024];
    [socket close];
}

- (void)setVolumeAction:(NSString *)action {
    [configManager updateKey:@"double_click_volume_action" forValue:action];
    [configManager save];
    [self reloadSettingsModel];
}

- (NSString *)triggerKeyFromCell:(TableViewCellWithEntry *)cell {
    if ([cell.title.text isEqualToString:@"Volume Up"]) return ZX_TRIGGER_VOLUME_UP;
    if ([cell.title.text isEqualToString:@"Home Button"]) return ZX_TRIGGER_HOME;
    return ZX_TRIGGER_VOLUME_DOWN;
}

- (void)setAction:(NSString *)action forTrigger:(NSString *)triggerKey {
    NSMutableDictionary *trigger = [self triggerConfigForKey:triggerKey];
    trigger[@"enabled"] = @(YES);
    trigger[@"action"] = action;
    [self saveTriggerConfig:trigger forKey:triggerKey];
}

- (void)setCount:(NSInteger)count forTrigger:(NSString *)triggerKey {
    NSMutableDictionary *trigger = [self triggerConfigForKey:triggerKey];
    trigger[@"enabled"] = @(YES);
    trigger[@"count"] = @(count);
    [self saveTriggerConfig:trigger forKey:triggerKey];
}

- (void)chooseScriptForTrigger:(NSString *)triggerKey fromCell:(UITableViewCell *)cell {
    NSArray<NSString *> *scripts = [self availableScriptPaths];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Run Script"
        message:scripts.count ? @"Choose the script for this trigger." : @"No .bdl scripts were found."
        preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *script in scripts) {
        NSString *title = [[script lastPathComponent] stringByDeletingPathExtension];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSMutableDictionary *trigger = [self triggerConfigForKey:triggerKey];
            trigger[@"enabled"] = @(YES);
            trigger[@"action"] = ZX_ACTION_RUN_SCRIPT;
            trigger[@"script"] = script;
            [self saveTriggerConfig:trigger forKey:triggerKey];
        }]];
        if (sheet.actions.count >= 18) break;
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"Enter Path..." style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self handleTriggerScriptTap:(TableViewCellWithEntry *)cell];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = cell;
        pop.sourceRect = cell.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)handleTriggerTap:(TableViewCellWithEntry*)cell {
    NSString *triggerKey = [self triggerKeyFromCell:cell];
    NSMutableDictionary *trigger = [self triggerConfigForKey:triggerKey];
    NSString *title = [self triggerTitle:triggerKey];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
        message:[NSString stringWithFormat:@"Current: %@", [self triggerSummaryForKey:triggerKey]]
        preferredStyle:UIAlertControllerStyleActionSheet];

    if ([trigger[@"enabled"] boolValue]) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Disable Trigger" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            NSMutableDictionary *updated = [self triggerConfigForKey:triggerKey];
            updated[@"enabled"] = @(NO);
            [self saveTriggerConfig:updated forKey:triggerKey];
        }]];
    } else {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Enable Trigger" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSMutableDictionary *updated = [self triggerConfigForKey:triggerKey];
            updated[@"enabled"] = @(YES);
            [self saveTriggerConfig:updated forKey:triggerKey];
        }]];
    }

    for (NSInteger count = 1; count <= 5; count++) {
        NSString *clickWord = count == 1 ? @"click" : @"clicks";
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%ld %@", (long)count, clickWord] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self setCount:count forTrigger:triggerKey];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"Run Script..." style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self chooseScriptForTrigger:triggerKey fromCell:cell];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Toggle Panel" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setAction:ZX_ACTION_TOGGLE_PANEL forTrigger:triggerKey];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Stop Script" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setAction:ZX_ACTION_STOP_SCRIPT forTrigger:triggerKey];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Toggle Recording" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setAction:ZX_ACTION_TOGGLE_RECORDING forTrigger:triggerKey];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Smart Toggle" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setAction:ZX_ACTION_SMART_TOGGLE forTrigger:triggerKey];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = cell;
        pop.sourceRect = cell.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)handleVolumeActionTap:(TableViewCellWithEntry*)cell {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Trigger Action"
        message:@"Choose the action fired by the Double-click Volume Down event."
        preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Smart Toggle" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setVolumeAction:ZX_ACTION_SMART_TOGGLE];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Toggle Panel" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setVolumeAction:ZX_ACTION_TOGGLE_PANEL];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Stop Script" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setVolumeAction:ZX_ACTION_STOP_SCRIPT];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Toggle Recording" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setVolumeAction:ZX_ACTION_TOGGLE_RECORDING];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Run Default Script" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setVolumeAction:ZX_ACTION_RUN_SCRIPT];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = cell;
        pop.sourceRect = cell.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)handleTriggerScriptTap:(TableViewCellWithEntry*)cell {
    NSString *triggerKey = [self triggerKeyFromCell:cell];
    NSMutableDictionary *trigger = [self triggerConfigForKey:triggerKey];
    NSString *current = trigger[@"script"] ?: @"";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Default Trigger Script"
        message:@"Paste a .bdl path to run from this trigger."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"/var/mobile/Library/ZXTouch/scripts/example.bdl";
        textField.text = current;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSMutableDictionary *updated = [self triggerConfigForKey:triggerKey];
        updated[@"script"] = @"";
        [self saveTriggerConfig:updated forKey:triggerKey];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *path = alert.textFields.firstObject.text ?: @"";
        NSMutableDictionary *updated = [self triggerConfigForKey:triggerKey];
        updated[@"enabled"] = @(YES);
        updated[@"action"] = ZX_ACTION_RUN_SCRIPT;
        updated[@"script"] = path;
        [self saveTriggerConfig:updated forKey:triggerKey];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handleWebServerWithSwitchCellInstance:(UISwitch*)s {
    if (![s isOn]) {
        ZXRemoteDashboardSetEnabled(NO);
        [self reloadSettingsModel];
        return;
    }

    if (!ZXRemoteDashboardSetEnabled(YES)) {
        [s setOn:NO animated:YES];
        NSString *dashboardError = ZXRemoteDashboardLastError();
        [Util showAlertBoxWithOneOption:self title:@"Dashboard unavailable"
            message:dashboardError.length ? dashboardError : @"Unable to start the local dashboard."
            buttonString:@"OK"];
        return;
    }

    [Util showAlertBoxWithOneOption:self title:@"Remote Dashboard"
        message:[NSString stringWithFormat:@"Open this address from a device on the same Wi-Fi:\n\n%@", ZXRemoteDashboardURL()]
        buttonString:@"OK"];
    [self reloadSettingsModel];
}

- (void)handleDashboardURLTap:(TableViewCellWithEntry *)cell {
    NSString *url = ZXRemoteDashboardURL();
    UIPasteboard.generalPasteboard.string = url;
    [Util showAlertBoxWithOneOption:self title:@"Dashboard URL"
        message:[NSString stringWithFormat:@"%@\n\nCopied to the clipboard.", url]
        buttonString:@"OK"];
}

- (void)handleDarkModeToggle:(UISwitch*)s {
    BOOL dark = [s isOn];
    [configManager updateKey:@"dark_mode" forValue:@(dark)];
    [configManager save];

    [[NSUserDefaults standardUserDefaults] setBool:dark forKey:@"dark_mode"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // Apply to all app windows immediately (iOS 13+)
    if (@available(iOS 13.0, *)) {
        UIUserInterfaceStyle style = dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
        for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *win in ((UIWindowScene *)scene).windows) {
                    win.overrideUserInterfaceStyle = style;
                }
            }
        }
    }

    // Notify SpringBoard to apply dark mode to the panel (command 903)
    Socket *socket = [[Socket alloc] init];
    [socket connect:@"127.0.0.1" byPort:6000];
    [socket send:@"903"];
    [socket recv:1024];
    [socket close];
}

- (void)handleCreditsTap:(TableViewCellWithEntry*)cell {
    // Show a brief about alert
    [Util showAlertBoxWithOneOption:self title:@"ZXTouch Rootless"
        message:@"iOS 16 Rootless (Dopamine) port by Epic0001\nhttps://github.com/Epic0001/zxtouchrootless"
        buttonString:@"OK"];
}

- (void)handleExamplesTap:(TableViewCellWithEntry*)cell {
    NSArray *examples = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:EXAMPLE_SCRIPTS_PATH error:nil];
    NSString *message = [NSString stringWithFormat:@"%lu bundled examples installed in:\n%@", (unsigned long)examples.count, EXAMPLE_SCRIPTS_PATH];
    [Util showAlertBoxWithOneOption:self title:@"Example Scripts" message:message buttonString:@"OK"];
}

- (void)handleRegistryTap:(TableViewCellWithEntry*)cell {
    NSDictionary *registry = [NSDictionary dictionaryWithContentsOfFile:SCRIPT_REGISTRY_PATH];
    NSString *version = registry[@"version"] ?: @"missing";
    NSString *examplesPath = registry[@"examplesPath"] ?: EXAMPLE_SCRIPTS_PATH;
    NSArray *scripts = registry[@"scripts"] ?: @[];
    NSString *message = [NSString stringWithFormat:@"Registry version: %@\nScripts: %lu\nExamples: %@", version, (unsigned long)scripts.count, examplesPath];
    [Util showAlertBoxWithOneOption:self title:@"Script Registry" message:message buttonString:@"OK"];
}

- (void)handleTouchIndicatorWithEntryCellInstance:(TableViewCellWithEntry*)cell {
    if ([cell isSelected])
    {
        UIStoryboard *sb = [UIStoryboard storyboardWithName:@"SettingPages" bundle:nil];
        TouchIndicatorConfigurationViewController *touchIndicatorConfigurationViewController = [sb instantiateViewControllerWithIdentifier:@"TouchIndicatorConfigurationPage"];
        [self.navigationController pushViewController:touchIndicatorConfigurationViewController animated:YES];
        //[self.navigationController setTitle:@"Touch Indicator"];
    }

}


//配置每个section(段）有多少row（行） cell
//默认只有一个section
-(NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{
    return cellsForEachSection[section].count;
}

-(NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return sections.count;
}

//每行显示什么东西
-(UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath{

    UITableViewCell *result;
    

    NSInteger indexInCurrentSection = indexPath.row;

    
    NSArray* cellList = cellsForEachSection[indexPath.section];

    NSDictionary *cellInfo = cellList[indexInCurrentSection];
    if ([cellInfo[@"type"] intValue] == SETTING_CELL_SWITCH)
    {
        static NSString *cellID = @"SwitchCell";

        TableViewCellWithSwitch *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
        
        //判断队列里面是否有这个cell 没有自己创建，有直接使用
        if (cell == nil) {
            //没有,创建一个
            cell = [[TableViewCellWithSwitch alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
        }
        
        cell.title.text = cellInfo[@"title"];
        cell.title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        cell.iconView.image = ZXSettingsSymbol([self iconNameForCellTitle:cellInfo[@"title"]]);
        cell.iconView.tintColor = [UIColor systemBlueColor];
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        [cell.switchBtn removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
        [cell.switchBtn addTarget:self action:NSSelectorFromString(cellInfo[@"switch_click_handler"]) forControlEvents:UIControlEventValueChanged];
        [cell.switchBtn setOn:[cellInfo[@"switch_init_status"] boolValue]];
        
        result = cell;
    }
    else if ([cellInfo[@"type"] intValue] == SETTING_CELL_ENTRY)
    {
        static NSString *cellID = @"EntryCell";

        TableViewCellWithEntry *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
        
        //判断队列里面是否有这个cell 没有自己创建，有直接使用
        if (cell == nil) {
            //没有,创建一个
            NSLog(@"create a setting cell switch");
            cell = [[TableViewCellWithEntry alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
        }
        
        cell.title.text = cellInfo[@"title"];
        cell.subTitle.text = cellInfo[@"secondary_title"];
        cell.title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        cell.subTitle.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        cell.subTitle.textColor = [UIColor secondaryLabelColor];
        cell.iconView.image = ZXSettingsSymbol([self iconNameForCellTitle:cellInfo[@"title"]]);
        cell.iconView.tintColor = [UIColor systemBlueColor];
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.clickHandler = cellInfo[@"row_click_handler"];
        
        result = cell;
    }
    
    
    return result;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    UITableViewCell *cell = [_tableView cellForRowAtIndexPath:indexPath];
    if ([cell isKindOfClass:[TableViewCellWithEntry class]])
    {
        TableViewCellWithEntry *entry = (TableViewCellWithEntry*)cell;
        [self performSelector:NSSelectorFromString(entry.clickHandler) withObject:entry];
    }
}

// Override to support editing the table view.
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {

}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}


- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *resultView = [[UIView alloc] init];
    //view.backgroundColor = [UIColor greenColor];
    
    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    title.textColor = [UIColor secondaryLabelColor];

    title.text = sections[section];

    
    [resultView addSubview:title];
    
    [[title.leftAnchor constraintEqualToAnchor:resultView.leftAnchor constant:20] setActive:YES];
    [[title.bottomAnchor constraintEqualToAnchor:resultView.bottomAnchor constant:-5] setActive:YES];

    return resultView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 38;
}
/*
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/

@end
