#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Procursus"
BUNDLE_ID="org.procursus.jailed"
PAYLOAD_DIR="Payload"
APP_DIR="${PAYLOAD_DIR}/${APP_NAME}.app"
OUTPUT_IPA="Procursus-Jailed.ipa"

echo "=== Building Jailed IPA: ${OUTPUT_IPA} ==="

rm -rf "${PAYLOAD_DIR}" "${OUTPUT_IPA}"
mkdir -p "${APP_DIR}/bootstrap"

# 1. Collect compiled files
if [ -d "build_strap/strap" ] && [ -n "$(ls -A build_strap/strap 2>/dev/null)" ]; then
    echo "Copying bootstrap tree..."
    cp -af build_strap/strap/* "${APP_DIR}/bootstrap/" || true
fi

if [ -d "build_dist" ]; then
    echo "Extracting deb packages into bootstrap..."
    for deb in build_dist/*.deb; do
        if [ -f "$deb" ]; then
            dpkg-deb -x "$deb" "${APP_DIR}/bootstrap/" || true
        fi
    done
fi

if [ -z "$(ls -A "${APP_DIR}/bootstrap" 2>/dev/null)" ]; then
    echo "Bootstrap empty, fetching official Procursus rootless bootstrap..."
    curl -sL https://apt.procurs.us/bootstraps/1900/bootstrap-iphoneos-arm64.tar.zst | zstdcat - | tar -xpkf - -C "${APP_DIR}/bootstrap/" || true
fi

# 2. Compile minimal iOS launcher executable if not already present
LAUNCHER_SRC=$(mktemp /tmp/launcher_XXXXXX.m)
cat << 'EOF' > "${LAUNCHER_SRC}"
#import <UIKit/UIKit.h>
#import <sys/utsname.h>

@interface TerminalViewController : UIViewController <UITextFieldDelegate>
@property (strong, nonatomic) UITextView *outputView;
@property (strong, nonatomic) UITextField *inputField;
@property (strong, nonatomic) UIView *inputContainer;
@property (strong, nonatomic) NSLayoutConstraint *inputBottomConstraint;
@property (strong, nonatomic) NSString *currentDir;
@end

@implementation TerminalViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    self.currentDir = paths.firstObject;
    
    self.outputView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.outputView.translatesAutoresizingMaskIntoConstraints = NO;
    self.outputView.backgroundColor = [UIColor blackColor];
    self.outputView.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.2 alpha:1.0];
    self.outputView.font = [UIFont fontWithName:@"Menlo-Regular" size:13] ?: [UIFont fontWithName:@"Courier" size:13];
    self.outputView.editable = NO;
    self.outputView.layoutManager.allowsNonContiguousLayout = NO;
    [self.view addSubview:self.outputView];
    
    self.inputContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.inputContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.inputContainer.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    [self.view addSubview:self.inputContainer];
    
    UILabel *promptLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    promptLabel.translatesAutoresizingMaskIntoConstraints = NO;
    promptLabel.textColor = [UIColor greenColor];
    promptLabel.font = [UIFont fontWithName:@"Menlo-Bold" size:14] ?: [UIFont boldSystemFontOfSize:14];
    promptLabel.text = @"$ ";
    [self.inputContainer addSubview:promptLabel];
    
    self.inputField = [[UITextField alloc] initWithFrame:CGRectZero];
    self.inputField.translatesAutoresizingMaskIntoConstraints = NO;
    self.inputField.textColor = [UIColor whiteColor];
    self.inputField.font = [UIFont fontWithName:@"Menlo-Regular" size:13] ?: [UIFont fontWithName:@"Courier" size:13];
    self.inputField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.inputField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.inputField.returnKeyType = UIReturnKeySend;
    self.inputField.delegate = self;
    self.inputField.tintColor = [UIColor greenColor];
    [self.inputContainer addSubview:self.inputField];
    
    self.inputBottomConstraint = [self.inputContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [self.outputView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.outputView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.outputView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [self.outputView.bottomAnchor constraintEqualToAnchor:self.inputContainer.topAnchor],
        
        [self.inputContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.inputContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.inputContainer.heightAnchor constraintEqualToConstant:44],
        self.inputBottomConstraint,
        
        [promptLabel.leadingAnchor constraintEqualToAnchor:self.inputContainer.leadingAnchor constant:10],
        [promptLabel.centerYAnchor constraintEqualToAnchor:self.inputContainer.centerYAnchor],
        [promptLabel.widthAnchor constraintEqualToConstant:20],
        
        [self.inputField.leadingAnchor constraintEqualToAnchor:promptLabel.trailingAnchor],
        [self.inputField.trailingAnchor constraintEqualToAnchor:self.inputContainer.trailingAnchor constant:-10],
        [self.inputField.centerYAnchor constraintEqualToAnchor:self.inputContainer.centerYAnchor],
        [self.inputField.heightAnchor constraintEqualToConstant:36]
    ]];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    
    struct utsname sysInfo;
    uname(&sysInfo);
    [self appendOutput:[NSString stringWithFormat:@"[Procursus Jailed Environment]\nDevice: %s | OS: %s\nType 'help' for available commands.\n\n$ ", sysInfo.machine, sysInfo.release]];
    
    [self.inputField becomeFirstResponder];
}

- (void)keyboardWillShow:(NSNotification *)note {
    CGRect kbFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    self.inputBottomConstraint.constant = -kbFrame.size.height + self.view.safeAreaInsets.bottom;
    [UIView animateWithDuration:[note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue] animations:^{
        [self.view layoutIfNeeded];
    }];
    [self scrollToBottom];
}

- (void)keyboardWillHide:(NSNotification *)note {
    self.inputBottomConstraint.constant = 0;
    [UIView animateWithDuration:[note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue] animations:^{
        [self.view layoutIfNeeded];
    }];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    NSString *cmd = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    textField.text = @"";
    if (cmd.length > 0) {
        [self appendOutput:[NSString stringWithFormat:@"%@\n", cmd]];
        [self executeCommand:cmd];
        [self appendOutput:@"$ "];
    }
    return YES;
}

- (void)appendOutput:(NSString *)text {
    self.outputView.text = [self.outputView.text stringByAppendingString:text];
    [self scrollToBottom];
}

- (void)scrollToBottom {
    if (self.outputView.text.length > 0) {
        NSRange bottom = NSMakeRange(self.outputView.text.length - 1, 1);
        [self.outputView scrollRangeToVisible:bottom];
    }
}

- (void)executeCommand:(NSString *)cmd {
    if ([cmd isEqualToString:@"clear"]) {
        self.outputView.text = @"";
        return;
    }
    if ([cmd isEqualToString:@"help"]) {
        [self appendOutput:@"Commands:\n  help, clear, pwd, cd <dir>, ls, id, uname, cat <file>\n  Or run any binary in the bootstrap.\n\n"];
        return;
    }
    if ([cmd hasPrefix:@"cd"]) {
        NSString *target = [cmd substringFromIndex:2];
        target = [target stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (target.length == 0) target = NSHomeDirectory();
        if (![target hasPrefix:@"/"]) target = [self.currentDir stringByAppendingPathComponent:target];
        
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:target isDirectory:&isDir] && isDir) {
            self.currentDir = target;
        } else {
            [self appendOutput:[NSString stringWithFormat:@"cd: no such file or directory: %@\n", target]];
        }
        return;
    }
    if ([cmd isEqualToString:@"pwd"]) {
        [self appendOutput:[NSString stringWithFormat:@"%@\n", self.currentDir]];
        return;
    }
    if ([cmd isEqualToString:@"ls"] || [cmd hasPrefix:@"ls "]) {
        NSError *err = nil;
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.currentDir error:&err];
        if (err) {
            [self appendOutput:[NSString stringWithFormat:@"ls: %@\n", err.localizedDescription]];
        } else {
            [self appendOutput:[NSString stringWithFormat:@"%@\n", [files componentsJoinedByString:@"  "]]];
        }
        return;
    }
    
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *bootstrapPath = [bundlePath stringByAppendingPathComponent:@"bootstrap"];
    NSString *binPath = [NSString stringWithFormat:@"%@/var/jb/bin:%@/var/jb/usr/bin:%@/bin:%@/usr/bin:/bin:/usr/bin", bootstrapPath, bootstrapPath, bootstrapPath, bootstrapPath];
    
    setenv("PATH", [binPath UTF8String], 1);
    setenv("HOME", [self.currentDir UTF8String], 1);
    chdir([self.currentDir UTF8String]);
    
    FILE *fp = popen([cmd UTF8String], "r");
    if (!fp) {
        [self appendOutput:[NSString stringWithFormat:@"sh: execution error: %@\n", cmd]];
        return;
    }
    char buf[1024];
    NSMutableString *res = [NSMutableString string];
    while (fgets(buf, sizeof(buf), fp) != NULL) {
        [res appendFormat:@"%s", buf];
    }
    pclose(fp);
    if (res.length > 0) {
        [self appendOutput:res];
    }
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = [[TerminalViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
EOF

echo "Compiling iOS App launcher..."
if command -v xcrun &>/dev/null; then
    xcrun -sdk iphoneos clang -arch arm64 \
        -miphoneos-version-min=15.0 \
        -fobjc-arc \
        -framework UIKit -framework Foundation -framework CoreGraphics \
        "${LAUNCHER_SRC}" -o "${APP_DIR}/${APP_NAME}"
    rm -f "${LAUNCHER_SRC}"
else
    echo "Warning: xcrun not found, creating dummy binary"
    touch "${APP_DIR}/${APP_NAME}"
    chmod +x "${APP_DIR}/${APP_NAME}"
fi

# 3. Create Info.plist
cat << EOF > "${APP_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
    <key>UIRequiredDeviceCapabilities</key>
    <array>
        <string>arm64</string>
    </array>
</dict>
</plist>
EOF

# 4. Sign binary with ldid if available
if command -v ldid &>/dev/null; then
    echo "Signing with ldid..."
    ldid -S "${APP_DIR}/${APP_NAME}" || true
fi

# 5. Pack into .ipa
echo "Packaging into ${OUTPUT_IPA}..."
zip -qry "${OUTPUT_IPA}" "${PAYLOAD_DIR}"
rm -rf "${PAYLOAD_DIR}"

echo "=== Successfully generated: ${OUTPUT_IPA} ==="
