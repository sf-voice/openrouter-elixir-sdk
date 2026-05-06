{:ok, _} = Application.ensure_all_started(:bypass)
{:ok, _} = Finch.start_link(name: OpenrouterSdk.TestFinch)

Application.put_env(:openrouter_sdk, :finch_name, OpenrouterSdk.TestFinch)

ExUnit.start()
