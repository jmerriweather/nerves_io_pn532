defmodule Nerves.IO.PN532.MifareClient do
  use Nerves.IO.PN532.Base

  def start_target_detection(pid) do    
    GenServer.cast(pid, {:start_target_detection, :iso_14443_type_a})
  end

  def stop_target_detection(pid) do    
    GenServer.cast(pid, :stop_target_detection)
  end

  def authenticate(pid, device_id, block, key_type, key, card_id) do    
    command =
      case key_type do
        :key_a -> 0x60
        :key_b -> 0x61
      end
    #data = <<block :: binary-size(1), key, card_id>>
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