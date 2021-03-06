#!/bin/bash

# https://gist.github.com/949831
# http://blog.carbonfive.com/2011/05/04/automated-ad-hoc-builds-using-xcode-4/

# command line OTA distribution references and examples
# http://nachbaur.com/blog/how-to-automate-your-iphone-app-builds-with-hudson
# http://nachbaur.com/blog/building-ios-apps-for-over-the-air-adhoc-distribution
# http://blog.octo.com/en/automating-over-the-air-deployment-for-iphone/
# http://www.neat.io/posts/2010/10/27/automated-ota-ios-app-distribution.html

project_dir=`OpenAR`

# Configuration
environment_name="staging"
keychain="ci_keys"
keychain_password="super secret"
workspace="OpenAR.xcodeproj"
scheme="Ad Hoc"
info_plist="$project_dir/Info.plist"
environment_plist="$environment_name.plist"
environment_info_plist="$environment_name-Info.plist"
product_name="My App $environment_name"
mobileprovision="$project_dir/dev_prof/openAR.mobileprovision"
provisioning_profile="iPhone Distribution: My Company, LLC"
build_number="%env.BUILD_NUMBER%"
artifacts_url="http://my_ci_server.example/artifacts/$build_number"
display_image_name="Icon-57.png"
full_size_image_name="Icon-512.png"

function failed()
{
local error=${1:-Undefined error}
echo "Failed: $error" >&2
exit 1
}

function validate_keychain()
{
# unlock the keychain containing the provisioning profile's private key and set it as the default keychain
security unlock-keychain -p "$keychain_password" "$HOME/Library/Keychains/$keychain.keychain"
security default-keychain -s "$HOME/Library/Keychains/$keychain.keychain"

#describe the available provisioning profiles
echo "Available provisioning profiles"
security find-identity -p codesigning -v

#verify that the requested provisioning profile can be found
(security find-certificate -a -c "$provisioning_profile" -Z | grep ^SHA-1) || failed provisioning_profile
}

function describe_sdks()
{
#list the installed sdks
echo "Available SDKs"
xcodebuild -showsdks
}

function describe_workspace()
{
#describe the project workspace
echo "Available schemes"
xcodebuild -list -workspace $workspace
}

function increment_version()
{
cd "OpenAR"
agvtool -noscm new-version -all $build_number
cd ..
}

function set_environment()
{
#copy the info plist for the selected environment into place
cp -v "MyApp/$environment_info_plist" $info_plist || failed environment_plist
#copy the environment settings plist into place
cp -v "MyApp/$environment_plist" "MyApp/environment.plist" || failed environment

#extract settings from the Info.plist file
info_plist_domain=$(ls $info_plist | sed -e 's/\.plist//')
short_version_string=$(defaults read "$info_plist_domain" CFBundleShortVersionString)
bundle_identifier=$(defaults read "$info_plist_domain" CFBundleIdentifier)
echo "Environment set to $bundle_identifier at version $short_version_string"
}

function build_app()
{
local devired_data_path="$HOME/Library/Developer/Xcode/DerivedData"

#get the name of the workspace to be build, used as the prefix of the DerivedData directory for this build
local workspace_name=$(echo "$workspace" | sed -n 's/\([^\.]\{1,\}\)\.xcworkspace/\1/p')
#build the app
echo "Running xcodebuild > xcodebuild_output ..."

#  disabled overriding PRODUCT_NAME, setting applies to all built targets in Xcode 4 which renames static library target dependencies and breaks linking
#  xcodebuild -verbose -workspace "$workspace" -scheme "$scheme" -sdk iphoneos -configuration Release clean build PRODUCT_NAME="$product_name" >| xcodebuild_output
xcodebuild -verbose -workspace "$workspace" -scheme "$scheme" -sdk iphoneos -configuration Release clean build >| xcodebuild_output

if [ $? -ne 0 ]
then
tail -n20 xcodebuild_output
failed xcodebuild
fi

#locate this project's DerivedData directory
local project_derived_data_directory=$(grep -oE "$workspace_name-([a-zA-Z0-9]+)[/]" xcodebuild_output | sed -n "s/\($workspace_name-[a-z]\{1,\}\)\//\1/p" | head -n1)
local project_derived_data_path="$devired_data_path/$project_derived_data_directory"
#locate the .app file

#  infer app name since it cannot currently be set using the product name, see comment above
#  project_app="$product_name.app"
project_app=$(ls -1 "$project_derived_data_path/Build/Products/Release-iphoneos/" | grep ".*\.app$" | head -n1)

# if [ $(ls -1 "$project_derived_data_path/Build/Products/Release-iphoneos/$project_app" | wc -l) -ne 1 ]
if [ $(ls -1 "$project_derived_data_path/Build/Products/Release-iphoneos/" | grep ".*\.app$" | wc -l) -ne 1 ]
then
echo "Failed to find a single .app build product."
# echo "Failed to locate $project_derived_data_path/Build/Products/Release-iphoneos/$project_app"
failed locate_built_product
fi
echo "Built $project_app in $project_derived_data_path"

#copy app and dSYM files to the working directory
cp -Rf "$project_derived_data_path/Build/Products/Release-iphoneos/$project_app" $project_dir
cp -Rf "$project_derived_data_path/Build/Products/Release-iphoneos/$project_app.dSYM" $project_dir

#rename app and dSYM so that multiple environments with the same product name are identifiable
echo "Retrieving build products..."
rm -rf $project_dir/$bundle_identifier.app
rm -rf $project_dir/$bundle_identifier.app.dSYM
mv -f "$project_dir/$project_app" "$project_dir/$bundle_identifier.app"
echo "$project_dir/$bundle_identifier.app"
mv -f "$project_dir/$project_app.dSYM" "$project_dir/$bundle_identifier.app.dSYM"
echo "$project_dir/$bundle_identifier.app.dSYM"
project_app=$bundle_identifier.app

#relink CodeResources, xcodebuild does not reliably construct the appropriate symlink
rm "$project_app/CodeResources"
ln -s "$project_app/_CodeSignature/CodeResources" "$project_app/CodeResources"
}

function sign_app()
{
echo "Codesign as \"$provisioning_profile\", embedding provisioning profile $mobileprovision"
#sign build for distribution and package as a .ipa
xcrun -sdk iphoneos PackageApplication "$project_dir/$project_app" -o "$project_dir/$project_app.ipa" --sign "$provisioning_profile" --embed "$mobileprovision" || failed codesign
}

function verify_app()
{
#verify the resulting app
codesign -d -vvv --file-list - "$project_dir/$project_app" || failed verification
}

function build_ota_plist()
{
echo "Generating $project_app.plist"
cat << EOF > $project_app.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
<key>items</key>
<array>
<dict>
<key>assets</key>
<array>
<dict>
<key>kind</key>
<string>software-package</string>
<key>url</key>
<string>$artifacts_url/$project_app.ipa</string>
</dict>
<dict>
<key>kind</key>
<string>full-size-image</string>
<key>needs-shine</key>
<true/>
<key>url</key>
<string>$artifacts_url/$full_size_image_name</string>
</dict>
<dict>
<key>kind</key>
<string>display-image</string>
<key>needs-shine</key>
<true/>
<key>url</key>
<string>$artifacts_url/$display_image_name</string>
</dict>
</array>
<key>metadata</key>
<dict>
<key>bundle-identifier</key>
<string>$bundle_identifier</string>
<key>bundle-version</key>
<string>$short_version_string $build_number</string>
<key>kind</key>
<string>software</string>
<key>subtitle</key>
<string>$environment_name</string>
<key>title</key>
<string>$project_app</string>
</dict>
</dict>
</array>
</dict>
</plist>
EOF
}

echo "**** Validate Keychain"
validate_keychain
echo
echo "**** Describe SDKs"
describe_sdks
echo
echo "**** Describe Workspace"
describe_workspace
echo
echo "**** Set Environment"
set_environment
echo
echo "**** Increment Bundle Version"
increment_version
echo
echo "**** Build"
build_app
echo
echo "**** Package Application"
sign_app
echo
echo "**** Verify"
verify_app
echo
echo "**** Prepare OTA Distribution"
build_ota_plist
echo
echo "**** Complete!"
