{{flutter_js}}
{{flutter_build_config}}

(function () {
  // The Flutter service worker is intentionally unregistered in index.html, so
  // {{flutter_service_worker_version}} is null → main.dart.js?v=null, a STABLE
  // url browsers cache forever (every deploy looked stale). Prefer the app's own
  // build version (set in index.html, bumped per deploy) so main.dart.js gets a
  // fresh url whenever we ship.
  const swVersion = {{flutter_service_worker_version}};
  const buildVersion =
    (typeof window !== 'undefined' && window.__rlinkBuildV) || swVersion || 'r';
  const config = window._flutter && window._flutter.buildConfig;
  if (config && Array.isArray(config.builds)) {
    for (const build of config.builds) {
      if (!build || !build.mainJsPath) continue;
      const separator = build.mainJsPath.includes('?') ? '&' : '?';
      build.mainJsPath = `${build.mainJsPath}${separator}v=${buildVersion}`;
    }
  }
  window._flutter.loader.load();
})();
