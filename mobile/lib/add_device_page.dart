part of 'main.dart';

class AddDevicePage extends StatefulWidget {
  const AddDevicePage(
      {super.key, required this.api, required this.boundIds, this.discovery});
  final Se9Api api;
  final Set<String> boundIds;
  final UdpDiscovery? discovery;

  @override
  State<AddDevicePage> createState() => _AddDevicePageState();
}

class _AddDevicePageState extends State<AddDevicePage> {
  late final discovery = widget.discovery ?? UdpDiscovery();
  late final boundIds = {...widget.boundIds};
  List<DiscoveredDevice> devices = [];
  bool searching = false;
  String? bindingId;
  String message = '安装并启动 NAS 后，连接同一 Wi-Fi 搜索设备';
  bool get busy => searching || bindingId != null;

  Future<void> search() async {
    if (busy) return;
    setState(() {
      searching = true;
      message = '正在搜索局域网设备…';
    });
    try {
      final result = await discovery.discover();
      if (!mounted) return;
      setState(() {
        devices = result;
        message = result.isEmpty
            ? '未发现设备，请确认 NAS 已启动、手机与 NAS 在同一网络，并允许局域网权限'
            : '发现 ${result.length} 台设备';
      });
    } catch (error) {
      if (mounted) setState(() => message = '搜索失败：$error');
    } finally {
      if (mounted) setState(() => searching = false);
    }
  }

  Future<void> bind(DiscoveredDevice device) async {
    if (busy || boundIds.contains(device.deviceId)) return;
    if (widget.api.cloudToken == null) {
      setState(() => message = '请返回首页登录账号后再绑定');
      return;
    }
    setState(() {
      bindingId = device.deviceId;
      message = '正在绑定 ${device.name}…';
    });
    try {
      final claim = await discovery.pair(device);
      if (claim == null) throw Exception('未收到设备的绑定凭据，请重试');
      await widget.api.confirmClaim(device.deviceId, claim.claimString,
          claimRequestId: claim.requestId);
      if (!mounted) return;
      setState(() {
        boundIds.add(device.deviceId);
        message = '${device.name} 绑定成功，返回首页即可上传和下载文件';
      });
    } catch (error) {
      if (mounted) setState(() => message = '绑定失败：$error');
    } finally {
      if (mounted) setState(() => bindingId = null);
    }
  }

  Future<void> configureAddress() async {
    final controller = TextEditingController(text: widget.api.baseUrl);
    final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('本地设备地址'),
                content: TextField(
                    controller: controller,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                        labelText: '设备地址',
                        hintText: 'http://192.168.1.50:8443')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, controller.text.trim()),
                      child: const Text('保存')),
                ]));
    if (!mounted || value == null) return;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.host.isEmpty ||
        !{'http', 'https'}.contains(uri.scheme)) {
      setState(() => message = '设备地址格式错误');
      return;
    }
    final address = value.replaceFirst(RegExp(r'/$'), '');
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('se9.device.baseUrl', address);
    widget.api.baseUrl = address;
    if (mounted) setState(() => message = '本地设备地址已保存；账号设备仍通过设备列表访问');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('添加设备')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
            child: ExpansionTile(
                initiallyExpanded: true,
                leading: const Icon(Icons.install_desktop),
                title: const Text('安装 NAS 程序'),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
              const Text(
                  '1. 在 Linux NAS 上编译与 CPU 架构匹配的程序。\n2. 挂载数据目录，把 device 目录复制到 NAS 后在其中执行安装命令。\n3. 启动服务后，让手机和 NAS 连接同一 Wi-Fi，再搜索并绑定。'),
              const SizedBox(height: 12),
              const SelectableText(
                  'cd device && sudo python3 deploy/install_nas.py --storage-root /vos/workspace/demo'),
              const SizedBox(height: 8),
              const Text(
                  '请按实际数据目录修改 storage-root。完整编译、依赖和安装步骤见项目 device/se9-c/README.md。'),
              const SizedBox(height: 8),
              Text('云服务：${widget.api.cloudBaseUrl}'),
            ])),
        ListTile(
            leading: const Icon(Icons.settings_ethernet),
            title: const Text('配置本地设备地址'),
            subtitle: const Text('用于本地直连调试；不能代替账号绑定'),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy ? null : configureAddress),
        const Divider(),
        FilledButton.icon(
            onPressed: busy ? null : search,
            icon: const Icon(Icons.wifi_find),
            label: Text(searching ? '正在搜索…' : '搜索设备')),
        if (busy) const LinearProgressIndicator(),
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(message)),
        for (final device in devices)
          Card(
              child: ListTile(
                  leading: const Icon(Icons.storage),
                  title: Text(device.name),
                  subtitle: Text(
                      '${device.address.address}:${device.port}\n${device.deviceId}'),
                  isThreeLine: true,
                  trailing: TextButton(
                      onPressed: busy || boundIds.contains(device.deviceId)
                          ? null
                          : () => bind(device),
                      child: Text(boundIds.contains(device.deviceId)
                          ? '已绑定'
                          : bindingId == device.deviceId
                              ? '绑定中…'
                              : '绑定')))),
      ]));
}

class TransferStatusCard extends StatelessWidget {
  const TransferStatusCard(
      {super.key,
      required this.name,
      required this.transport,
      required this.state,
      required this.direction,
      this.phase = '',
      this.progress,
      this.onPause});
  final String name, transport, state, direction, phase;
  final double? progress;
  final VoidCallback? onPause;

  static String channelLabel(String transport) => switch (transport) {
        '直连' => 'WebRTC · 直连',
        'TURN 中继' => 'WebRTC · TURN 中继',
        'WebRTC' => 'WebRTC · 路径确认中',
        '' => '正在建立通道',
        _ => transport,
      };

  @override
  Widget build(BuildContext context) {
    final label = channelLabel(transport);
    final stateLabel = const {
          'preparing': '准备中',
          'transferring': '传输中',
          'verifying': '校验中',
          'completed': '已完成',
          'paused': '已暂停',
          'cancelled': '已取消',
          'failed': '失败',
        }[state] ??
        state;
    final detail = switch (transport) {
      '直连' => '文件数据通过 WebRTC 直接传到设备',
      'TURN 中继' => '文件数据通过 WebRTC，经 TURN 服务器中继',
      '服务器转发' => '文件数据经云服务器转发',
      '本地直连（HTTP）' => '文件数据通过本地设备地址传输',
      _ => '连接结果以实际建立的传输通道为准',
    };
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.swap_vert),
                const SizedBox(width: 8),
                Expanded(
                    child: Text('传输通道：$label',
                        style: const TextStyle(fontWeight: FontWeight.bold))),
                if (onPause != null)
                  IconButton(
                      tooltip: '暂停传输',
                      onPressed: onPause,
                      icon: const Icon(Icons.pause)),
              ]),
              Text(state == 'preparing' && phase.isNotEmpty ? phase : detail),
              Text(
                  '${direction == 'download' ? '下载' : '上传'} · $name · $stateLabel'),
              if (progress != null && state != 'preparing')
                Text('${(progress! * 100).toStringAsFixed(1)}%'),
            ])));
  }
}
