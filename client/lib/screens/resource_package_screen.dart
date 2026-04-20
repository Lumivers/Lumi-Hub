import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/resource_package_service.dart';
import '../theme/app_theme.dart';

class ResourcePackageScreen extends StatefulWidget {
  const ResourcePackageScreen({super.key});

  @override
  State<ResourcePackageScreen> createState() => _ResourcePackageScreenState();
}

class _ResourcePackageScreenState extends State<ResourcePackageScreen> {
  final TextEditingController _bundleUrlController = TextEditingController();
  final TextEditingController _bucketEndpointController = TextEditingController();
  final TextEditingController _bucketPrefixController = TextEditingController();
  final TextEditingController _bucketKeywordController = TextEditingController();
  final ResourcePackageService _resourceService = ResourcePackageService();

  bool _loading = true;
  bool _searchingBucket = false;
  bool _installingPackage = false;
  String _activeResourceVersion = '';
  String _resourceRootPath = '';
  int _resourceInstalledCount = 0;
  String _resourceUpdatedLabel = '-';
  final List<ResourceBucketObject> _bucketResults = <ResourceBucketObject>[];
  String? _selectedBucketKey;

  @override
  void initState() {
    super.initState();
    _loadResourceSnapshot();
  }

  Future<void> _loadResourceSnapshot() async {
    setState(() => _loading = true);
    final snapshot = await _resourceService.loadSnapshot();
    if (!mounted) return;

    setState(() {
      _activeResourceVersion = snapshot.activeVersion;
      _resourceRootPath = snapshot.rootPath;
      _resourceInstalledCount = snapshot.installedCount;
      _resourceUpdatedLabel = snapshot.updatedAt == null
          ? '-'
          : snapshot.updatedAt!.toLocal().toString();
      if (_bundleUrlController.text.trim().isEmpty) {
        _bundleUrlController.text = snapshot.bundleUrl;
      }
      if (_bucketEndpointController.text.trim().isEmpty) {
        _bucketEndpointController.text = snapshot.bucketEndpoint;
      }
      if (_bucketPrefixController.text.trim().isEmpty) {
        _bucketPrefixController.text = snapshot.bucketPrefix;
      }
      _loading = false;
    });
  }

  Future<void> _searchBucketPackages() async {
    final endpoint = _bucketEndpointController.text.trim();
    final prefix = _bucketPrefixController.text.trim();
    final keyword = _bucketKeywordController.text.trim();

    if (endpoint.isEmpty) {
      _showSnack('请先输入 Bucket 地址', isError: true);
      return;
    }

    setState(() => _searchingBucket = true);
    try {
      final results = await _resourceService.searchBucketZipPackages(
        bucketEndpoint: endpoint,
        bucketPrefix: prefix,
        keyword: keyword,
      );

      if (!mounted) return;

      setState(() {
        _bucketResults
          ..clear()
          ..addAll(results);

        if (_bucketResults.isNotEmpty) {
          _selectedBucketKey = _bucketResults.first.key;
          _bundleUrlController.text = _bucketResults.first.url;
        } else {
          _selectedBucketKey = null;
        }
      });

      _showSnack('检索完成：找到 ${results.length} 个 ZIP 资源包');
    } catch (e) {
      _showSnack('检索失败: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _searchingBucket = false);
      }
    }
  }

  void _selectBucketResource(ResourceBucketObject item) {
    setState(() {
      _selectedBucketKey = item.key;
      _bundleUrlController.text = item.url;
    });
  }

  String? _inferVersionFromKey(String? key) {
    if (key == null || key.trim().isEmpty) return null;
    final filename = key.split('/').last;
    final withoutExt = filename.toLowerCase().endsWith('.zip')
        ? filename.substring(0, filename.length - 4)
        : filename;
    final sanitized = withoutExt.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return sanitized.isEmpty ? null : sanitized;
  }

  Future<void> _downloadResourcePackage() async {
    final url = _bundleUrlController.text.trim();
    if (url.isEmpty) {
      _showSnack('请先输入资源包 URL', isError: true);
      return;
    }

    setState(() => _installingPackage = true);
    try {
      final result = await _resourceService.downloadAndInstall(
        bundleUrl: url,
        versionHint: _inferVersionFromKey(_selectedBucketKey),
      );
      if (!mounted) return;
      await _loadResourceSnapshot();
      _showSnack('资源包安装完成: ${result.version}（${result.fileCount} 个文件）');
    } catch (e) {
      _showSnack('下载资源包失败: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _installingPackage = false);
      }
    }
  }

  String _formatSize(int? sizeBytes) {
    if (sizeBytes == null || sizeBytes <= 0) return '-';
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = sizeBytes.toDouble();
    var index = 0;
    while (size >= 1024 && index < units.length - 1) {
      size /= 1024;
      index += 1;
    }
    final fixed = index == 0 ? size.toStringAsFixed(0) : size.toStringAsFixed(1);
    return '$fixed ${units[index]}';
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.redAccent : null,
      ),
    );
  }

  @override
  void dispose() {
    _bundleUrlController.dispose();
    _bucketEndpointController.dispose();
    _bucketPrefixController.dispose();
    _bucketKeywordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<LumiColors>()!;
    final baseBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: colors.divider.withValues(alpha: 0.6)),
    );
    final focusedBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: colors.accent, width: 1.4),
    );

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: colors.sidebar,
        title: const Text('可扩展资源包'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            decoration: BoxDecoration(
              color: colors.inputBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.divider.withValues(alpha: 0.2)),
            ),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.travel_explore_outlined, color: colors.subtext, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Bucket 资源检索',
                      style: TextStyle(
                        fontSize: 18,
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _bucketEndpointController,
                  decoration: InputDecoration(
                    hintText: '输入 Bucket 地址，例如 https://example-bucket.s3.amazonaws.com',
                    filled: true,
                    fillColor: colors.sidebar,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    enabledBorder: baseBorder,
                    border: baseBorder,
                    focusedBorder: focusedBorder,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _bucketPrefixController,
                        decoration: InputDecoration(
                          hintText: 'Prefix（可选）',
                          filled: true,
                          fillColor: colors.sidebar,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          enabledBorder: baseBorder,
                          border: baseBorder,
                          focusedBorder: focusedBorder,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _bucketKeywordController,
                        decoration: InputDecoration(
                          hintText: '关键字过滤（可选）',
                          filled: true,
                          fillColor: colors.sidebar,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          enabledBorder: baseBorder,
                          border: baseBorder,
                          focusedBorder: focusedBorder,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: (_searchingBucket || _installingPackage)
                            ? null
                            : _searchBucketPackages,
                        icon: _searchingBucket
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.search),
                        label: Text(_searchingBucket ? '检索中...' : '搜索资源包'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '检索结果：${_bucketResults.length} 项（仅 ZIP）',
                  style: TextStyle(color: colors.subtext, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Container(
                  constraints: BoxConstraints(
                    maxHeight: math.max(120, math.min(320, _bucketResults.length * 72)),
                  ),
                  decoration: BoxDecoration(
                    color: colors.sidebar.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: colors.divider.withValues(alpha: 0.3)),
                  ),
                  child: _bucketResults.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Text(
                              '暂无检索结果',
                              style: TextStyle(color: colors.subtext, fontSize: 12),
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _bucketResults.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color: colors.divider.withValues(alpha: 0.2),
                          ),
                          itemBuilder: (context, index) {
                            final item = _bucketResults[index];
                            final selected = item.key == _selectedBucketKey;
                            return ListTile(
                              dense: true,
                              selected: selected,
                              selectedTileColor: colors.accent.withValues(alpha: 0.12),
                              leading: Icon(
                                selected
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked,
                                size: 18,
                                color: selected ? colors.accent : colors.subtext,
                              ),
                              title: Text(
                                item.key,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 13),
                              ),
                              subtitle: Text(
                                '大小: ${_formatSize(item.sizeBytes)} · 时间: ${item.lastModified?.toLocal().toString() ?? '-'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: colors.subtext, fontSize: 11),
                              ),
                              onTap: () => _selectBucketResource(item),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          Container(
            decoration: BoxDecoration(
              color: colors.inputBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.divider.withValues(alpha: 0.2)),
            ),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.download_for_offline_outlined, color: colors.subtext, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '资源包下载与安装',
                      style: TextStyle(
                        fontSize: 18,
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _bundleUrlController,
                  decoration: InputDecoration(
                    hintText: '已选 URL（可手动编辑）',
                    filled: true,
                    fillColor: colors.sidebar,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    enabledBorder: baseBorder,
                    border: baseBorder,
                    focusedBorder: focusedBorder,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '当前版本: ${_activeResourceVersion.isEmpty ? '未安装' : _activeResourceVersion}',
                  style: TextStyle(color: colors.subtext, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  '已安装版本数: $_resourceInstalledCount',
                  style: TextStyle(color: colors.subtext, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  '缓存目录: ${_resourceRootPath.isEmpty ? '-' : _resourceRootPath}',
                  style: TextStyle(color: colors.subtext, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  '最近更新: $_resourceUpdatedLabel',
                  style: TextStyle(color: colors.subtext, fontSize: 12),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: (_searchingBucket || _installingPackage)
                            ? null
                            : _downloadResourcePackage,
                        icon: _installingPackage
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.download_for_offline_outlined),
                        label: Text(_installingPackage ? '下载中...' : '下载并安装所选资源'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: (_searchingBucket || _installingPackage)
                            ? null
                            : _loadResourceSnapshot,
                        icon: const Icon(Icons.refresh),
                        label: const Text('刷新资源状态'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
