# Nerves.IO.PN532

## Hardware

Any PN532 board should work as long as it supports UART, I've been using the following board to develop.

[NFC/RFID PN532 breakout Module](http://www.elecfreaks.com/store/nfcrfid-breakout-module-p-519.html)

[![NFC/RFID PN532 breakout Module](http://www.elecfreaks.com/store/images/NFC-Module.jpg "NFC/RFID PN532 breakout Module")](http://www.elecfreaks.com/store/nfcrfid-breakout-module-p-519.html "RFID PN532 breakout Module")

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed as:

  1. Add `nerves_io_pn532` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [{:nerves_io_pn532, "~> 0.1.0"}]
    end
    ```

  2. Ensure `nerves_io_pn532` is started before your application:

    ```elixir
    def application do
      [applications: [:nerves_io_pn532]]
    end
    ```

## How to use

```elixir
defmodule MifareClientImplementation do
  use Nerves.IO.PN532.MifareClient

  def card_detected(card = %{tg: target_number, sens_res: sens_res, sel_res: sel_res, nfcid: identifier}) do
    Logger.info("Detected new Mifare card with ID: #{Base.encode16(identifier)}")
  end

  def card_lost(card = %{tg: target_number, sens_res: sens_res, sel_res: sel_res, nfcid: identifier}) do
    Logger.info("Lost connection with Mifare card with ID: #{Base.encode16(identifier)}")
  end
end
```

```elixir
defmodule Example do
  def main do
    with {:ok, pid} <- MifareClientImplementation.start_link(),
         :ok <- MifareClientImplementation.open(pid, "COM3"),
         :ok <- MifareClientImplementation.start_target_detection(pid) do
      # ...
    end
  end
end
```