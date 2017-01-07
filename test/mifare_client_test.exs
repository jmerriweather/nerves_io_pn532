defmodule MifareClientTest do
  use Nerves.IO.PN532.MifareClient

  def card_detected(_card = %{nfcid: identifier}) do
    Logger.info("Detected 123 new Mifare card with ID: #{Base.encode16(identifier)}")
  end

  def card_lost(_card = %{nfcid: identifier}) do
    Logger.info("Lost 123 connection with Mifare card with ID: #{Base.encode16(identifier)}")
  end
end
