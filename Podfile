platform :ios, '14.0'

target 'LMS_StreamTest' do
  use_frameworks!
  
  pod 'CocoaAsyncSocket', '~> 7.6'

  target 'LMS_StreamTestTests' do
    inherit! :search_paths
  end

  target 'LMS_StreamTestUITests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '14.0'
      config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
      config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    end
  end
end
