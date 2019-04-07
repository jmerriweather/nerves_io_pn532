defmodule Nerves.IO.PN532.Base do
  @callback handle_detection(integer, binary) :: {:ok, term} | {:error, term}
  @callback setup(pid, map) :: :ok
  @callback handle_event(any, any) :: :ok | {:error, any}

  defmacro __using__(opts \\ []) do
    read_timeout = Keyword.get(opts, :read_timeout, 500)
    detection_interval = Keyword.get(opts, :detection_interval, 50)
    quote location: :keep do
      use GenServer
      @behaviour Nerves.IO.PN532.Base
      require Logger
      require Nerves.IO.PN532.Frames
      import Nerves.IO.PN532.Frames

      @read_timeout unquote(read_timeout)
      @detection_interval unquote(detection_interval)

      @wakeup_preamble <<0x55, 0x55, 0x00, 0x00, 0x00>>
      @sam_mode_normal <<0x14, 0x01, 0x00, 0x00>>
      @ack_frame <<0x00, 0xFF>>
      @nack_frame <<0xFF, 0x00>>

      # API
      @spec start_link :: {:ok, pid} | {:error, term}
      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, [], opts)
      end

      @spec open(pid, String.t, [pos_integer]) :: :ok | {:error, :already_open} | {:error, term}
      def open(pid, com_port, uart_speed \\ 115_200) do
        GenServer.call(pid, {:open, com_port, uart_speed})
      end

      @spec close(pid) :: :ok | {:error, :not_open}
      def close(pid) do
        GenServer.call(pid, :close)
      end

      @spec get_current_card(pid) :: {:ok, map} | {:error, term}
      def get_current_card(pid) do
        GenServer.call(pid, :get_current_card)
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


      def in_list_passive_target(pid, target, max_targets) do
        with {:ok, target_byte} <- get_target_type(target) do
          GenServer.call(pid, {:in_list_passive_target, target_byte, max_targets})
        else
          error -> {:error, error}
        end
      end

      @spec set_serial_baud_rate(pid, pos_integer) :: :ok | {:error, {atom, String.t}} | {:error, :timeout}
      def set_serial_baud_rate(pid, baud_rate) do
        GenServer.call(pid, {:set_serial_baud_rate, baud_rate})
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
        send(self(), :setup)
        {:ok, %{
                  uart_pid: pid,
                  uart_open: false,
                  uart_speed: 115200,
                  power_mode: :low_v_bat,
                  current_card: nil,
                  detection_ref: nil
              }}
      end

      defp write_bytes(pid, bytes), do: Nerves.UART.write(pid, bytes)

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

      defp get_error(error_byte) do
        case error_byte do
          0x01 -> {:target_timeout, "The target has not answered"}
          0x02 -> {:crc_error, "A CRC error has been detected by the CIU"}
          0x03 -> {:parity_error, "A Parity error has been detected by the CIU"}
          0x04 -> {:bit_count_error, "During an anti-collision/select operation (ISO/IEC14443-3 Type A and ISO/IEC18092 106 kbps passive mode), an erroneous Bit Count has been detected"}
          0x05 -> {:mifare_framing_error, "Framing error during Mifare operation"}
          0x06 -> {:abnormal_bit_collision, "An abnormal bit-collision has been detected during bit wise anti-collision at 106 kbps"}
          0x07 -> {:buffer_size_insufficient, "Communication buffer size insufficient"}
          0x09 -> {:rf_buffer_overflow, "RF Buffer overflow has been detected by the CIU (bit BufferOvfl of the register CIU_Error)"}
          0x0A -> {:rf_field_not_on_in_time, "In active communication mode, the RF field has not been switched on in time by the counterpart (as defined in NFCIP-1 standard)"}
          0x0B -> {:rf_protocol_error, "RF Protocol error"}
          0x0D -> {:temperature_error, "Temperature error: the internal temperature sensor has detected overheating, and therefore has automatically switched off the antenna drivers"}
          0x0E -> {:internal_buffer_overflow, "Internal buffer overflow"}
          0x10 -> {:invalid_parameter, "Invalid parameter (range, format, ...)"}
          0x12 -> {:dep_command_received_invalid, "The PN532 configured in target mode does not support the command received from the initiator (the command received is not one of the following: ATR_REQ, WUP_REQ, PSL_REQ, DEP_REQ, DSL_REQ, RLS_REQ"}
          0x13 -> {:dep_data_format_not_match_spec, "Mifare or ISO/IEC14443-4: The data format does not match to the specification. Depending on the RF protocol used, it can be: Bad length of RF received frame, Incorrect value of PCB or PFB, Incorrect value of PCB or PFB, NAD or DID incoherence."}
          0x14 -> {:mifare_authentication_error, "Mifare: Authentication error"}
          0x23 -> {:uid_check_byte_wrong, "ISO/IEC14443-3: UID Check byte is wrong"}
          0x25 -> {:dep_invalid_device_state, "Invalid device state, the system is in a state which does not allow the operation"}
          0x26 -> {:op_not_allowed, "Operation not allowed in this configuration (host controller interface)"}
          0x27 -> {:command_invalid_in_context, "This command is not acceptable due to the current context of the PN532 (Initiator vs. Target, unknown target number, Target not in the good state, ...)"}
          0x29 -> {:target_released_by_initiator, "The PN532 configured as target has been released by its initiator"}
          0x2A -> {:card_id_does_not_match, "PN532 and ISO/IEC14443-3B only: the ID of the card does not match, meaning that the expected card has been exchanged with another one."}
          0x2B -> {:card_disappeared, "PN532 and ISO/IEC14443-3B only: the card previously activated has disappeared."}
          0x2C -> {:target_initiator_nfcid3_mismatch, "Mismatch between the NFCID3 initiator and the NFCID3 target in DEP 212/424 kbps passive."}
          0x2D -> {:over_current_event, "An over-current event has been detected"}
          0x2E -> {:dep_nad_missing, "NAD missing in DEP frame"}
          _ -> {:unknown_error, "Unknown error"}
        end
      end

      defp detect_card(uart_pid, target_type, max_targets) do
        in_list_passive_target_command = <<0x4A, max_targets, target_type>>
        write_bytes(uart_pid, in_list_passive_target_command)

        receive do
          {:nerves_uart, com_port, <<0xD5, 0x4B, total_cards::signed-integer, rest::binary>>} ->
            handle_detection(total_cards, rest)
        after
          @read_timeout ->
            write_bytes(uart_pid, <<0x00, 0x00, 0xFF, @ack_frame, 0x00>>)
            {:error, :timeout}
        end
      end

      def handle_call(:get_current_card, _, state = %{current_card: card}) do
        {:reply, {:ok, card}, state}
      end

      def handle_call({:open, _com_port, _uart_speed}, _, state = %{uart_open: true}) do
        {:reply, {:error, :already_open}, state}
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
        {:reply, {:error, :not_open}, state}
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
            {:nerves_uart, com_port, firmware_version_response(ic_version, version, revision, support)} ->
              Logger.debug("Received firmware version frame on #{inspect com_port} with version: #{inspect version}.#{inspect revision}.#{inspect support}")
              {:ok, %{ic_version: ic_version, version: version, revision: revision, support: support}}
          after
            @read_timeout ->
              {:error, :timeout}
          end

        {:reply, response, %{state | power_mode: new_power_mode}}
      end

      def handle_call({:set_serial_baud_rate, baud_rate}, _from, state = %{uart_pid: uart_pid}) do
        new_power_mode = wakeup(state)

        response =
          # convert baud rate number into baud rate command byte
          with {:ok, baudrate_byte} <- get_baud_rate(baud_rate) do
            command = <<0x10>> <> baudrate_byte
            # send set baud rate command
            write_bytes(uart_pid, command)

            receive do
              # wait for ACK message
              {:nerves_uart, com_port, @ack_frame} ->
                receive do
                  # wait for success message
                  {:nerves_uart, com_port, <<0xD5, 0x11>>} ->
                    # send ACK frame to let the PN532 know we are ready to change
                    write_bytes(uart_pid, <<0x00, 0x00, 0xFF, @ack_frame, 0x00>>)
                    # sleep for 20ms
                    Process.sleep(20)
                    # change baud rate of UART
                    with :ok <- Nerves.UART.configure(uart_pid, speed: baud_rate) do
                      {:ok, baud_rate}
                    else
                      error -> error
                    end
                  {:nerves_uart, com_port, <<0xD5, 0x11, status>>} ->
                    error =  get_error(status)
                    {:error, error}
                after
                  @read_timeout ->
                    {:error, :timeout}
                end
            after
              @read_timeout * 2 ->
                {:error, :timeout}
            end
          else
            error -> {:error, error}
          end

        {:reply, response, state}
      end

      def handle_call({:in_data_exchange, device_id, cmd, data}, _from, state = %{uart_pid: uart_pid}) do
        new_power_mode = wakeup(state)

        write_bytes(uart_pid, <<0x40>> <> <<device_id>> <> <<cmd>> <> data)
        response =
          receive do
            # Data exchange was successful, this is returned on successful authentication
            {:nerves_uart, com_port, <<0xD5, 0x41, 0>>} -> :ok
            # Data exchange was successful, with resulting data
            {:nerves_uart, com_port, <<0xD5, 0x41, 0, rest::binary>>} -> {:ok, rest}
            # Error happened
            {:nerves_uart, com_port, <<0xD5, 0x41, status>>} ->
              error =  get_error(status)
              {:error, error}
          after
            @read_timeout ->
              {:error, :timeout}
          end

        {:reply, response, %{state | power_mode: new_power_mode}}
      end

      def handle_call({:in_list_passive_target, target_type, max_targets}, _from, state = %{uart_pid: uart_pid}) do
        new_power_mode = wakeup(state)

        response = detect_card(uart_pid, target_type, max_targets)

        {:reply, response, %{state | power_mode: new_power_mode}}
      end

      def handle_cast(:stop_target_detection, state = %{detection_ref: nil}) do
        Logger.error("Target detection has not been started")
        {:noreply, state}
      end

      def handle_cast(:stop_target_detection, state = %{uart_pid: uart_pid, detection_ref: detection_ref}) when detection_ref != nil do
        Process.cancel_timer(detection_ref)
        # send ACK frame to cancel last command
        write_bytes(uart_pid, <<0x00, 0x00, 0xFF, @ack_frame, 0x00>>)
        {:noreply, %{state | detection_ref: nil, current_card: nil}}
      end

      def handle_cast({:start_target_detection, _type}, state = %{detection_ref: detection_ref}) when detection_ref != nil do
        Logger.error("Target detection has already been started")
        {:noreply, state}
      end

      def handle_cast({:start_target_detection, target_type}, state) do
        with {:ok, target_byte} <- get_target_type(target_type) do
          Logger.debug("Starting target detection")
          Process.send(self(), {:detect_target, target_byte}, [])
        end
        {:noreply, state}
      end

      def handle_info(:setup, state) do
        setup(self(), state)

        {:noreply, state}
      end

      def handle_info({:detect_target, target_type}, state = %{uart_pid: uart_pid, current_card: current_card}) do
        new_power_mode = wakeup(state)

        new_state =
          with {:ok, card} <- detect_card(uart_pid, target_type, 1) do
            if current_card != card do
              handle_event(:card_detected, card)
            end
            %{state | current_card: card}
          else
            _ ->
              if current_card != nil do
                handle_event(:card_lost, current_card)
              end
              %{state | current_card: nil}
          end

        detection_ref = Process.send_after(self(), {:detect_target, target_type}, @detection_interval)

        {:noreply, %{new_state | power_mode: new_power_mode, detection_ref: detection_ref}}
      end

      def handle_info({:nerves_uart, com_port, <<0x7F>>}, state) do
        Logger.error("Received Error frame on #{inspect com_port}")
        {:noreply, state}
      end

      def handle_info({:nerves_uart, com_port, @ack_frame}, state) do
        Logger.debug("Received ACK frame on #{inspect com_port}")
        {:noreply, state}
      end

      def handle_info({:nerves_uart, com_port, @nack_frame}, state) do
        Logger.debug("Received NACK frame on #{inspect com_port}")
        {:noreply, state}
      end
    end
  end
end
