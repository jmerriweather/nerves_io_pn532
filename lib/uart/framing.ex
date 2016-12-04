defmodule Nerves.IO.PN532.UART.Framing do  
  @behaviour Nerves.UART.Framing
  import Nerves.IO.PN532.Frames
  require Nerves.IO.PN532.Frames
  require Logger
  
  use Bitwise

  @preamble 0x00
  @postamble 0x00
  @startcode1 0x00
  @startcode2 0xFF
  @host_to_pn532 <<0xD4>>
  @pn532_to_host <<0xD5>>

  @wakeup_preamble <<0x55, 0x55, 0x00, 0x00, 0x00>>
  @sam_mode_normal <<0x14, 0x01, 0x00, 0x00>>
  @ack_frame <<0x00, 0xFF>>
  @nack_frame <<0xFF, 0x00>>

  defmodule State do
    @moduledoc false
    defstruct [
      process_state: :preamble,
      frame_length: 0,
      processed: <<>>,
      in_process: <<>>
    ]
  end

  def init(_) do
    {:ok, %State{}}
  end

  def add_framing(<<@preamble, @startcode1, @startcode2, @ack_frame, @postamble>> = command, state) do
    Logger.debug("About to send ACK: #{inspect command}")
    {:ok, command, state}
  end

  def add_framing(<<@preamble, @startcode1, @startcode2, @nack_frame, @postamble>> = command, state) do
    Logger.debug("About to send NACK: #{inspect command}")
    {:ok, command, state}
  end

  def add_framing(@wakeup_preamble = command, state) do
    Logger.debug("About to send: #{inspect command}")
    {:ok, command, state}
  end

  def add_framing(data, state) do
    command = build_command_frame(<<0xD4>>, data)
    Logger.debug("About to send: #{inspect command}")
    {:ok, command, state}
  end

  def remove_framing(data, state) do
    {new_processed, new_in_process, new_process_state, frames, new_frame_length} = 
      process_data(state.processed, state.in_process <> data, 
        %{frame_state: state.process_state,
          frames: [], 
          frame_length: state.frame_length})

    new_state = %{state | processed: new_processed, 
                          in_process: new_in_process, 
                          process_state: new_process_state,
                          frame_length: new_frame_length}
                          
    rc = if buffer_empty?(new_state), do: :ok, else: :in_frame
    {rc, frames, new_state}
  end

  def frame_timeout(state) do
    partial_frame = {:partial, state.processed <> state.in_process}
    new_state = %{state | processed: <<>>, in_process: <<>>}
    {:ok, [partial_frame], new_state}
  end

  def flush(direction, state) when direction == :receive or direction == :both do
    %{state | processed: <<>>, in_process: <<>>}
  end
  def flush(_direction, state) do
    state
  end

  def buffer_empty?(state) do
    state.processed == <<>> and state.in_process == <<>>
  end

  # No more data to process
  defp process_data(processed_frame, <<>>, %{frame_state: frame_state, frames: frames, frame_length: frame_length}) do
    {processed_frame, <<>>, frame_state, frames, frame_length}
  end

  # Full ACK Frame
  defp process_data(_processed_frame, <<@preamble, @startcode1, @startcode2, 0x00, 0xFF, @postamble, rest::binary>>, %{frames: frames} = state) do
    completed_frame = <<0x00, 0xFF>>
    process_data(<<>>, rest, %{state | frames: [completed_frame | frames]})
  end

  # Full NACK Frame
  defp process_data(_processed_frame, <<@preamble, @startcode1, @startcode2, 0xFF, 0x00, @postamble, rest::binary>>, %{frames: frames} = state) do
    completed_frame = <<0xFF, 0x00>>
    process_data(<<>>, rest, %{state | frames: [completed_frame | frames]})
  end

  # If we're not waiting for an ACK/NACK assume that we are processing a normal frame
  defp process_data(processed_frame, to_process, %{frame_state: frame_state, frames: frames, frame_length: frame_length} = state) do
    Logger.debug("Processing data: #{inspect frame_state}, frame: #{inspect processed_frame}, data: #{inspect to_process}")
    case to_process do
      # find preamble
      <<@preamble, rest::binary>> when frame_state == :preamble ->
        process_data(<<>>, rest, %{state | frame_state: :start_code_one})
      # find first start code
      <<@startcode1, rest::binary>> when frame_state == :start_code_one ->
        process_data(processed_frame, rest, %{state | frame_state: :start_code_two})
      # find second start code
      <<@startcode2, rest::binary>> when frame_state == :start_code_two ->
        process_data(processed_frame, rest, %{state | frame_state: :frame_length})
      # found first ack start code
      <<0x00, rest::binary>> when frame_state == :frame_length ->
        process_data(processed_frame <> <<0x00>>, rest, %{state | frame_state: :ack_code_two, frame_length: 0})
      # found second ack start code
      <<0xFF, rest::binary>> when frame_state == :ack_code_two ->
        process_data(processed_frame <> <<0xFF>>, rest, %{state | frame_state: :postamble})
      # found first nack start code
      <<0xFF, rest::binary>> when frame_state == :frame_length ->
        process_data(processed_frame <> <<0xFF>>, rest, %{state | frame_state: :nack_code_two, frame_length: 0})
      # found second nack start code
      <<0x00, rest::binary>> when frame_state == :nack_code_two ->
        process_data(processed_frame <> <<0x00>>, rest, %{state | frame_state: :postamble})
      # get the frame length and store it for later
      <<length::integer-signed, rest::binary>> when frame_state == :frame_length ->
        Logger.debug("Found data length: #{length}")
        process_data(processed_frame, rest, %{state | frame_state: :frame_length_checksum, frame_length: length})
      # get the length checksum
      <<length_checksum::integer-signed, rest::binary>> when frame_state == :frame_length_checksum ->
        # TODO: do length checksum check
        process_data(processed_frame, rest, %{state | frame_state: :frame_identifier_and_data})
      # when we have no bytes remaining, change the frame state to check the checksum
      <<rest::binary>> when frame_state == :frame_identifier_and_data and frame_length == 0 ->
        Logger.debug("Data length: #{frame_length}")
        process_data(processed_frame, rest, %{state | frame_state: :message_checksum})
      # when we're on the last byte of the message, change the frame state to check the checksum
      <<message::binary-size(1), rest::binary>> when frame_state == :frame_identifier_and_data and frame_length == 1 ->
        Logger.debug("Data length: #{frame_length}")
        process_data(processed_frame <> message, rest, %{state | frame_state: :message_checksum})
      # keep processing data until we've read the full frame length
      <<message::binary-size(1), rest::binary>> when frame_state == :frame_identifier_and_data ->
        Logger.debug("Data length: #{frame_length}")
        process_data(processed_frame <> message, rest, %{state | frame_state: :frame_identifier_and_data, frame_length: frame_length - 1})
      # get the data checksum
      <<message_checksum::integer-signed, rest::binary>> when frame_state == :message_checksum ->
        # TODO: do message checksum check
        process_data(processed_frame, rest, %{state | frame_state: :postamble})
      # finally get the postamble, add the frame to the list of frames and keep processing any additional data
      <<@postamble, rest::binary>> when frame_state == :postamble ->
        process_data(<<>>, rest, %{state | frame_state: :preamble, frames: [processed_frame | frames]})
      # we've got rubbish data, skip this byte and keep trying
      <<rubbish::binary-size(1), rest::binary>> ->
        Logger.warn("Ignoring rubbish data: #{rubbish}")
        process_data(processed_frame, rest, state)
      # shouldn't be here
      unknown ->
        Logger.debug("Unknown data: #{inspect unknown}, #{inspect frame_state}, frame: #{inspect processed_frame}, data: #{inspect to_process}")
    end
  end
end