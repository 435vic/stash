{
  pathSources = {
    config = {
      files."pathAsString".source = "/testing/string";
    };
    
    "test 1" = {
      expr = cfg: cfg.files."pathAsString".source.static;
      expected = true;
    };
  };
}
