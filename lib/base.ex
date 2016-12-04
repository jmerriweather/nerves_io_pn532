defmodule Nerves.IO.PN532.Base do
  use GenServer

  require Logger
  require Nerves.IO.PN532.Frames

  import Nerves.IO.PN532.Frames

  @read_timeout 500
  @detection_interval 50

  @wakeup_preamble <<0x55, 0x55, 0x00, 0x00, 0x00>>
  @sam_mode_normal <<0x14, 0x01, 0x00, 0x00>>
  @ack_frame <<0x00, 0xFF>>
  @nack_frame <<0xFF, 0x00>>

  # API
  
  def start_link do
    GenServer.start_link(__MODULE__, [])
  end

  def open(pid, com_port, uart_speed \\ 115_200) do
    GenServer.call(pid, {:open, com_port, uart_speed}) 
  end

  def close(pid) do
    GenServer.call(pid, :close) 
  end

  def start_target_detection(pid, type) do    
    GenServer.cast(pid, {:start_target_detection, type})
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

    GenServer.call(pid, {:in_data_exchange, device_id, command, <<block, key, card_id>>})
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

  def in_data_exchange(pid, device_id, cmd, addr, data) do
    GenServer.call(pid, {:in_data_exchange, device_id, cmd, <<addr, data>>})
  end

  def in_data_exchange(pid, device_id, cmd, data) do
    GenServer.call(pid, {:in_data_exchange, device_id, cmd, data})
  end

  def get_firmware_version(pid) do
    GenServer.call(pid, :get_firmware_version)
  end

  def in_list_passive_target(pid, target) do
    with {:ok, target_byte} <- get_target_type(target) do
      GenServer.call(pid, {:in_list_passive_target, target_byte})
    else
      error -> {:error, error}
    end
  end

  def set_serial_baud_rate(pid, baud_rate) do
    with {:ok, baudrate_byte} <- get_baud_rate(baud_rate) do
      GenServer.call(pid, {:set_serial_baud_rate, baudrate_byte})
    else
      error -> {:error, error}
    end
  end

  @spec get_target_type(atom) :: {:ok, binary} | :invalid_target_type
  def get_target_type(target) do
    case target do
      :iso_14443_type_a -> {:ok, 0x00}
      :felica_212 -> {:ok, 0x01}
      :felica_424 -> {:ok, 0x02}
      :iso_14443_type_b -> {:ok, 0x03}
      :jewel -> {:ok, 0x04}
      _ -> :invalid_target_type
    end
  end

  @spec get_baud_rate(number) :: {:ok, binary} | :invalid_baud_rate
  def get_baud_rate(baudrate) do
    case baudrate do
      9_600 -> {:ok, <<0x00>>}
      19_200 -> {:ok, <<0x01>>}
      38_400 -> {:ok, <<0x02>>}
      57_600 -> {:ok, <<0x03>>}
      115_200 -> {:ok, <<0x04>>}
      230_400 -> {:ok, <<0x05>>}
      460_800 -> {:ok, <<0x06>>}
      921_600 -> {:ok, <<0x07>>}
      1_288_000 -> {:ok, <<0x08>>}
      _ -> :invalid_baud_rate
    end
  end

  # GenServer

  def init(_) do
    {:ok, pid} = Nerves.UART.start_link
    {:ok, %{
              uart_pid: pid,
              uart_open: false,
              uart_speed: 115200,
              power_mode: :low_v_bat, 
              detection_ref: nil
           }}
  end

  defp write_bytes(pid, bytes) do
    Nerves.UART.write(pid, bytes)
  end

  defp wakeup(%{uart_pid: uart_pid, power_mode: :low_v_bat}) do
    Nerves.UART.write(uart_pid, @wakeup_preamble)
    Nerves.UART.write(uart_pid, @sam_mode_normal)
    receive do
      ack -> Logger.debug("SAM ACK: #{inspect ack}")
    after
      16 -> :timeout
    end

    receive do
      response -> Logger.debug("SAM response: #{inspect response}")
    after
      16 -> :timeout
    end

    :normal
  end

  defp wakeup(%{power_mode: power_mode}) do
    power_mode
  end

  def handle_call({:open, _com_port, _uart_speed}, _, state = %{uart_open: true}) do
    {:reply, :uart_already_open, state}
  end

  def handle_call({:open, com_port, uart_speed}, _from, state = %{uart_pid: uart_pid}) do     
    with :ok <- Nerves.UART.open(uart_pid, com_port, speed: uart_speed, active: true, framing: Nerves.IO.PN532.UART.Framing) do
      {:reply, :ok, %{state | uart_open: true}}
    else
      error -> 
        Logger.error("Error occured opening UART: #{inspect error}")
        {:reply, error, %{state | uart_speed: uart_speed}}
    end
  end

  def handle_call(_, _, state = %{uart_open: false}) do
    {:reply, :uart_not_open, state}
  end

  def handle_call(:close, _from, state = %{uart_pid: uart_pid}) do
    response = Nerves.UART.close(uart_pid)
    {:reply, response, %{state | uart_open: false}}
  end

  def handle_call(:get_firmware_version, _from, state = %{uart_pid: uart_pid}) do
    new_power_mode = wakeup(state)
    
    firmware_version_command = <<0x02>>
    write_bytes(uart_pid, firmware_version_command)
    response = 
      receive do
        {:nerves_uart, com_port, get_firmware_version_response(ic_version, version, revision, support)} ->
          Logger.debug("Received firmware version frame on #{inspect com_port} with version: #{inspect version}.#{inspect revision}.#{inspect support}")
          {:ok, %{ic_version: ic_version, version: version, revision: revision, support: support}}
      after
        @read_timeout ->
          {:error, :timeout}
      end

    {:reply, response, %{state | power_mode: new_power_mode}}
  end

  def handle_call({:in_data_exchange, device_id, cmd, data}, _from, state = %{uart_pid: uart_pid}) do
    new_power_mode = wakeup(state)

    write_bytes(uart_pid, <<0x40>> <> <<device_id>> <> <<cmd>> <> data)

    {:reply, :ok, %{state | power_mode: new_power_mode}}
  end

  def handle_call({:in_list_passive_target, target_type, max_targets}, _from, state = %{uart_pid: uart_pid}) do
    new_power_mode = wakeup(state)
    
    in_list_passive_target_command = <<0x4A, max_targets, target_type>>
    write_bytes(uart_pid, in_list_passive_target_command)

    card_id_response = 
      receive do
        # detected single card
        {:nerves_uart, com_port, <<0xD5, 0x4B, 0x01, in_list_passive_target_card(target_number, sens_res, sel_res, identifier)>>} ->
          Logger.info("Received InListPassiveTarget with new Mifare card detection frame on #{inspect com_port} with ID: #{inspect Base.encode16(identifier)}")
          {:ok, %{tg: target_number, sens_res: sens_res, sel_res: sel_res, nfcid: identifier}}
        
        # detected multiple cards
        {:nerves_uart, com_port, <<0xD5, 0x4B, total_cards::signed-integer, rest::binary>>} ->
          cards = for <<in_list_passive_target_card(target_number, sens_res, sel_res, identifier) <- rest>> do 
            %{tg: target_number, sens_res: sens_res, sel_res: sel_res, nfcid: identifier}
          end
          identifiers_in_base16 = cards |> Enum.map(fn(x) -> Base.encode16(x.nfcid) end)
          Logger.info("Received InListPassiveTarget with '#{inspect total_cards}' new Mifare cards detection frame on #{inspect com_port} with ID: #{inspect identifiers_in_base16}")
          {:ok, cards}
      after
        @read_timeout ->
          write_bytes(uart_pid, <<0x00, 0x00, 0xFF, @ack_frame, 0x00>>)
          Logger.info("Timeout InListPassiveTarget")
          {:error, :timeout}
      end

    {:reply, card_id_response, %{state | power_mode: new_power_mode}}
  end

  def handle_cast(:stop_target_detection, state = %{detection_ref: nil}) do
    Logger.info("Target detection has not been started")
    {:noreply, state}
  end

  def handle_cast(:stop_target_detection, state = %{uart_pid: uart_pid, detection_ref: detection_ref}) when detection_ref != nil do
    Process.cancel_timer(detection_ref)
    # send ACK frame to cancel last command
    write_bytes(uart_pid, <<0x00, 0x00, 0xFF, @ack_frame, 0x00>>)
    {:noreply, %{state | detection_ref: nil}}
  end

  def handle_cast({:start_target_detection, _type}, state = %{detection_ref: detection_ref}) when detection_ref != nil do
    Logger.info("Target detection has already been started")
    {:noreply, state}
  end

  def handle_cast({:start_target_detection, target_type}, state) do
    with {:ok, target_byte} <- get_target_type(target_type) do
      Logger.debug("Starting target detection")
      Process.send(self(), {:detect_target, target_byte}, [])
    end
    {:noreply, state}
  end

  def handle_info({:detect_target, target_type}, state = %{uart_pid: uart_pid}) do
    new_power_mode = wakeup(state)

    in_list_passive_target_command = <<0x4A, 0x01, target_type>>
    write_bytes(uart_pid, in_list_passive_target_command)
    
    detection_ref = Process.send_after(self(), {:detect_target, target_type}, @detection_interval)

    {:noreply, %{state | power_mode: new_power_mode, detection_ref: detection_ref}}
  end

  def handle_info({:nerves_uart, com_port, <<0x7F>>}, state) do
    Logger.error("Received Error frame on #{inspect com_port}")
    {:noreply, state}
  end

  def handle_info({:nerves_uart, _com_port, @ack_frame}, state) do
    #Logger.info("Received ACK frame on #{inspect com_port}")
    {:noreply, state}
  end

  def handle_info({:nerves_uart, _com_port, @nack_frame}, state) do
    #Logger.info("Received NACK frame on #{inspect com_port}")
    {:noreply, state}
  end
end
