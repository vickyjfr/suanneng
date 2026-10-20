# SE9 Mobile Demo

## 中文

这是 Flutter 移动端 Demo，目标平台为 iOS 15 及以上和 Android 10 及以上。当前版本连接 Ubuntu 独立文件服务，支持登录、局域网 UDP 设备发现、目录列表、批量选择、图片/视频分片上传和基础进度显示。UDP 发现结果展示设备签名，签名验证和绑定解密仍在接入中。

当前环境未安装 Flutter SDK，因此这里只提交源码和依赖配置，无法在本机执行 `flutter pub get` 或构建 iOS/Android 包。

```bash
flutter pub get
flutter run --dart-define=SE9_API=http://192.168.1.50:8443
```

当前工程已经设置：

- iOS `platform :ios, '15.0'`。
- Android `minSdk 29`。
- 通过安全配置注入 API 地址，不要把生产地址硬编码在源码中。

## English

This is the Flutter mobile demo targeting iOS 15+ and Android 10+. The current version connects to the independent Ubuntu file service and supports login, LAN UDP device discovery, directory listing, multi-file selection, photo/video chunked upload, and basic progress reporting. Discovery responses expose the device signature; signature verification and claim decryption are still being integrated.

Flutter SDK is not installed in the current environment, so the source and dependency configuration are provided but `flutter pub get` and iOS/Android builds cannot be executed here.

```bash
flutter pub get
flutter run --dart-define=SE9_API=http://192.168.1.50:8443
```

The current generated project sets:

- iOS `platform :ios, '15.0'`.
- Android `minSdk 29`.
- Inject API endpoints through secure configuration rather than hard-coding production addresses.
