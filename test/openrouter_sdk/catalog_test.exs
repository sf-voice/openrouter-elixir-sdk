defmodule OpenrouterSdk.CatalogTest do
  use ExUnit.Case, async: true

  alias OpenrouterSdk.Catalog.{Models, Providers}

  test "Models.list/0 returns a list (possibly empty before snapshot)" do
    assert is_list(Models.list())
  end

  test "Models.get/1 returns nil for missing ids" do
    assert Models.get("does/not-exist") == nil
  end

  test "Providers.list/0 returns a list" do
    assert is_list(Providers.list())
  end

  test "Models.version/0 returns a string" do
    assert is_binary(Models.version())
  end
end
