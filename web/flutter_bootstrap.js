{{flutter_js}}
{{flutter_build_config}}

(function () {
  const buildVersion = {{flutter_service_worker_version}};
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
