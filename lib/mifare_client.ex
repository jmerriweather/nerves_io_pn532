defmodule Nerves.IO.PN532.MifareClient do
  use Nerves.IO.PN532.Base

  def start_target_detection(pid) do    
    GenServer.cast(pid, {:start_target_detection, :iso_14443_type_a})
  end

  def stop_target_detection(pid) do    
    GenServer.cast(pid, :stop_target_detection)
  end

  def card_detected(card = %{nfcid: identifier}) do
    Logger.info("Detected new Mifare card with ID: #{Base.encode16(identifier)}")
  end

  def card_lost(card = %{nfcid: identifier}) do
    Logger.info("Lost connection with Mifare card with ID: #{Base.encode16(identifier)}")
  end

  def process_card_detection(1, in_list_passive_target_card(target_number, sens_res, sel_res, identifier)) do
    Logger.debug("Received Mifare card detection with ID: #{inspect Base.encode16(identifier)}")
    {:ok, %{tg: target_number, sens_res: sens_res, sel_res: sel_res, nfcid: identifier}}
  end

  def process_card_detection(total_cards, card_data) do
    cards = for <<in_list_passive_target_card(target_number, sens_res, sel_res, identifier) <- card_data>> do 
      %{tg: target_number, sens_res: sens_res, sel_res: sel_res, nfcid: identifier}
    end
    identifiers_in_base16 = cards |> Enum.map(fn(x) -> Base.encode16(x.nfcid) end)
    Logger.debug("Received '#{inspect total_cards}' new Mifare cards with IDs: #{inspect identifiers_in_base16}")
    {:ok, cards}
  end

  def authenticate(pid, device_id, block, key_type, key, card_id) do    
    command =
      case key_type do
        :key_a -> 0x60
        :key_b -> 0x61
      end
    data = <<block>> <> key <> card_id

    GenServer.call(pid, {:in_data_exchange, device_id, command, data})
  end

  def read(pid, device_id, block) do
    GenServer.call(pid, {:in_data_exchange, device_id, 0x30, <<block>>})
  end

  def write16(pid, device_id, block, <<data::binary-size(16)>>) do
    GenServer.call(pid, {:in_data_exchange, device_id, 0xA0, <<block, data>>})
  end

  def write4(pid, device_id, block, <<data::binary-size(4)>>) do
    GenServer.call(pid, {:in_data_exchange, device_id, 0xA2, <<block, data>>})
  end
end