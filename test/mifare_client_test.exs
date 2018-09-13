defmodule MifareClientTest do
  use Nerves.IO.PN532.MifareClient

  def setup(pid, state) do
    Logger.info("MifareClient initi")
  end

  def card_detected(_card = %{nfcid: identifier}) do
    Logger.info("Detected new Mifare card with ID: #{Base.encode16(identifier)}")
  end

  def card_lost(_card = %{nfcid: identifier}) do
    Logger.info("Lost connection with Mifare card with ID: #{Base.encode16(identifier)}")
  end
end
