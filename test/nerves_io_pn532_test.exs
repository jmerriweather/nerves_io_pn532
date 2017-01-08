defmodule Nerves.IO.PN532Test do
  use ExUnit.Case

  @test_uart "COM6"

  setup_all do
    # start mifare client genserver
    {:ok, pid} = MifareClientTest.start_link

    #open uart
    open_result = MifareClientTest.open(pid, @test_uart)

    # on_exit fn ->
    #   MifareClientTest.close(pid)
    # end

    {:ok, [client_open_result: open_result, mifare_client_pid: pid]}
  end

  test "open PN532 mifare client", %{client_open_result: result} do
    assert result == :ok
  end

  test "get PN532 firmware version", %{mifare_client_pid: pid} do
    {:ok, firmware_version} = MifareClientTest.get_firmware_version(pid)
    #IO.puts(inspect(firmware_version))
    assert firmware_version == %{ic_version: "2", revision: 6, support: 7, version: 1}
  end

  test "start and stop mifare target detection", %{mifare_client_pid: pid} do
    start_result = MifareClientTest.start_target_detection(pid)

    stop_result = MifareClientTest.stop_target_detection(pid)

    assert start_result == :ok
    assert stop_result == :ok
  end
end
