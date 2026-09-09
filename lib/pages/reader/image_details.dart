part of 'reader.dart';

class _ReaderImageDetailsView extends StatelessWidget {
  _ReaderImageDetailsView(
    this.reader, {
    required this.currentStart,
    required this.currentEnd,
  }) : images = (reader.isLoading ? null : reader.images) ?? const [],
       cid = reader.cid,
       sourceKey = reader.type.sourceKey,
       eid = reader.eid,
       chapter = reader.chapter;

  final _ReaderState reader;
  final List<String> images;
  final String cid;
  final String sourceKey;
  final String eid;
  final int chapter;
  final int currentStart;
  final int currentEnd;

  bool get canNavigate =>
      reader.mounted &&
      !reader.isLoading &&
      reader.cid == cid &&
      reader.eid == eid &&
      reader.chapter == chapter &&
      identical(reader.images, images);

  void goToImage(BuildContext context, int index) {
    if (!canNavigate) return;
    final perPage = reader.imagesPerPage;
    final page = reader.showSingleImageOnFirstPage()
        ? (index == 0 ? 1 : (index - 1) ~/ perPage + 2)
        : index ~/ perPage + 1;
    Navigator.of(context).pop();
    reader.toPage(page);
  }

  @override
  Widget build(BuildContext context) {
    final store = ReaderImageDetailsStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        return Scaffold(
          body: SmoothCustomScrollView(
            slivers: [
              SliverAppbar(
                style: AppbarStyle.shadow,
                title: Text('${"Image Information".tl} · E$chapter'),
              ),
              if (images.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('Not loaded'.tl)),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final imageKey = images[index];
                    final details = store.lookup(
                      imageKey,
                      sourceKey,
                      cid,
                      eid,
                      index + 1,
                    );
                    final isCurrent =
                        index >= currentStart && index < currentEnd;
                    final highlight = isCurrent
                        ? Theme.of(context).colorScheme.primaryContainer
                        : null;
                    return ExpansionTile(
                      key: PageStorageKey((cid, sourceKey, eid, index)),
                      initiallyExpanded: isCurrent,
                      backgroundColor: highlight,
                      collapsedBackgroundColor: highlight,
                      title: Text(
                        '${"Page".tl} ${index + 1}'
                        '${isCurrent ? " · ${"Current page".tl}" : ""}',
                      ),
                      leading: IconButton(
                        tooltip: 'Go to page'.tl,
                        icon: const Icon(Icons.open_in_new),
                        onPressed: canNavigate
                            ? () => goToImage(context, index)
                            : null,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(details?.state.tl ?? 'Not loaded'.tl),
                          if (details?.isStale == true)
                            SelectableText(
                              key: const PageStorageKey('stale-message'),
                              'Previous settings; waiting for refresh'.tl,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                        ],
                      ),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: SelectableText(
                            '${"Image key".tl}: $imageKey',
                            key: const PageStorageKey('image-key'),
                          ),
                        ),
                        if (details != null) ...[
                          SelectableText(
                            '${"State".tl}: ${details.state.tl}',
                            key: const PageStorageKey('processing-state'),
                          ),
                          for (final entry in details.values.entries)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: SelectableText(
                                '${entry.key.tl}: ${entry.value.tl}',
                                key: PageStorageKey(('detail', entry.key)),
                              ),
                            ),
                        ],
                      ],
                    );
                  }, childCount: images.length),
                ),
            ],
          ),
        );
      },
    );
  }
}
