Pod::Spec.new do |s|
  s.name = 'CMangaImageAI'
  s.version = '1.0.0'
  s.summary = 'Shared ONNX/OpenCV image inference for CManga Apple runners.'
  s.homepage = 'https://github.com/cliecy/CManga'
  s.license = { :type => 'GPL-3.0', :file => '../LICENSE' }
  s.author = 'CManga contributors'
  s.source = { :git => 'https://github.com/cliecy/CManga.git', :tag => s.version.to_s }
  s.ios.deployment_target = '16.3'
  s.osx.deployment_target = '13.3'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.dependency 'CMangaOnnxRuntime', '= 1.29.0'
  s.dependency 'CMangaOpenCV', '= 4.11.0'
  s.source_files = 'apple/*.{h,mm}', 'image_ai/engine.{h,cpp}', 'image_ai/image_memory.{h,cpp}'
  s.public_header_files = 'apple/CMangaImageAIPlugin.h'
  s.private_header_files = 'image_ai/engine.h', 'image_ai/image_memory.h', 'apple/metal_provider.h'
  s.header_mappings_dir = '.'
  s.requires_arc = true
  s.static_framework = true
  s.frameworks = 'Foundation', 'ImageIO', 'Metal'
  s.libraries = 'c++'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'GCC_ENABLE_CPP_EXCEPTIONS' => 'YES',
    'HEADER_SEARCH_PATHS' => '$(inherited) "$(PODS_XCFRAMEWORKS_BUILD_DIR)/CMangaOnnxRuntime/onnxruntime.framework/Headers"'
  }
end
