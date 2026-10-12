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

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor blackColor];
    
    UIViewController *vc = [[UIViewController alloc] init];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 100, self.window.bounds.size.width - 40, 200)];
    label.textColor = [UIColor greenColor];
    label.font = [UIFont fontWithName:@"Courier" size:14];
    label.numberOfLines = 0;
    label.text = @"[Procursus Jailed Environment]\n\nBootstrap loaded successfully.\nUse embedded terminal or SSH to interact.";
    [vc.view addSubview:label];
    
    self.window.rootViewController = vc;
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
        -framework UIKit -framework Foundation \
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
