part of 'settings_page.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  static const _configuredRepository = String.fromEnvironment(
    'CMANGA_REPOSITORY',
  );

  String? get _repository {
    final value = _configuredRepository.trim();
    return RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$',
        ).hasMatch(value)
        ? value
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final repository = _repository;
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("About".tl)),
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset(
                  'assets/app_icon.png',
                  width: 96,
                  height: 96,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'CManga',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'A little space for big stories.'.tl,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: colors.primary),
              ),
              const SizedBox(height: 16),
              Text(
                'CManga is a free and open-source app for comic reading.'.tl,
              ),
              const SizedBox(height: 16),
              Text(
                'Version @version'.tlParams({'version': '${App.version}+216'}),
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => showLicensePage(
                      context: context,
                      applicationName: 'CManga',
                      applicationVersion: '${App.version}+216',
                      applicationIcon: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Image.asset(
                          'assets/app_icon.png',
                          width: 64,
                          height: 64,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.description_outlined),
                    label: Text('Open-source licenses'.tl),
                  ),
                  if (repository != null)
                    OutlinedButton.icon(
                      onPressed: () =>
                          launchUrlString('https://github.com/$repository'),
                      icon: const Icon(Icons.code),
                      label: Text('Project repository'.tl),
                    ),
                ],
              ),
            ],
          ),
        ).toSliver(),
        ListTile(
          leading: const Icon(Icons.system_update_alt),
          title: Text('Check for updates'.tl),
          subtitle: Text(
            repository != null
                ? 'View published releases for @repository.'.tlParams({
                    'repository': repository,
                  })
                : _configuredRepository.trim().isEmpty
                ? 'No release service is configured for this build.'.tl
                : 'The configured release repository is invalid.'.tl,
          ),
          trailing: repository != null ? const Icon(Icons.open_in_new) : null,
          onTap: repository == null
              ? null
              : () =>
                    launchUrlString('https://github.com/$repository/releases'),
        ).toSliver(),
        if (repository == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Text(
              'Build with --dart-define=CMANGA_REPOSITORY=owner/repo to enable project and release links.'
                  .tl,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ).toSliver(),
        const Divider().toSliver(),
        ListTile(
          leading: const Icon(Icons.favorite_outline),
          title: Text('Built on open source'.tl),
          subtitle: Text(
            'CManga builds on Venera and Venera-SSR. Thanks to their authors and every contributor.'
                .tl,
          ),
        ).toSliver(),
        ListTile(
          title: Text('Venera-SSR upstream project'.tl),
          trailing: const Icon(Icons.open_in_new),
          onTap: () => launchUrlString('https://github.com/Kiastr/Venera-SSR'),
        ).toSliver(),
        ListTile(
          title: Text('Venera upstream project'.tl),
          trailing: const Icon(Icons.open_in_new),
          onTap: () => launchUrlString('https://github.com/venera-app/venera'),
        ).toSliver(),
        SliverPadding(
          padding: EdgeInsets.only(bottom: context.padding.bottom + 16),
        ),
      ],
    );
  }
}
