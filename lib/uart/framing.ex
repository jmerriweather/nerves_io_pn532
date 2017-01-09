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
  @pn532_to_host <<0xD5>>

  @wakeup_preamble <<0x55, 0x55, 0x00, 0x00, 0x00>>
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

  def checksum_length(length, length_checksum) do
    length + length_checksum == 0x00
  end

  def checksum_data(data, data_checksum) do
    dsc_checksum = checksum(@pn532_to_host <> data)
    dsc = ~~~data_checksum + 1
    Logger.debug("Data Checksum: #{inspect dsc_checksum}, Expected: #{dsc}")
    dsc_checksum + dsc == 0x00
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

  defp process_data(_processed_frame, <<@preamble, rest::binary>>, %{frame_state: :preamble} = state) do
    process_data(<<>>, rest, %{state | frame_state: :start_code_one})
  end

  defp process_data(processed_frame, <<@startcode1, rest::binary>>, %{frame_state: :start_code_one} = state) do
    process_data(processed_frame, rest, %{state | frame_state: :start_code_two})
  end

  defp process_data(processed_frame, <<@startcode2, rest::binary>>, %{frame_state: :start_code_two} = state) do
    process_data(processed_frame, rest, %{state | frame_state: :frame_length})
  end

  defp process_data(processed_frame, <<0x00, rest::binary>>, %{frame_state: :frame_length} = state) do
    process_data(processed_frame <> <<0x00>>, rest, %{state | frame_state: :ack_code_two, frame_length: 0})
  end

  defp process_data(processed_frame, <<0xFF, rest::binary>>, %{frame_state: :ack_code_two} = state) do
    process_data(processed_frame <> <<0xFF>>, rest, %{state | frame_state: :postamble})
  end

  defp process_data(processed_frame, <<0xFF, rest::binary>>, %{frame_state: :frame_length} = state) do
    process_data(processed_frame <> <<0xFF>>, rest, %{state | frame_state: :nack_code_two, frame_length: 0})
  end

  defp process_data(processed_frame, <<0x00, rest::binary>>, %{frame_state: :nack_code_two} = state) do
    process_data(processed_frame <> <<0x00>>, rest, %{state | frame_state: :postamble})
  end

  defp process_data(processed_frame, <<length::integer-unsigned, rest::binary>>, %{frame_state: :frame_length} = state) do
    Logger.debug("Found data length: #{length}")
    process_data(processed_frame, rest, %{state | frame_state: :frame_length_checksum, frame_length: length})
  end

  defp process_data(processed_frame, <<length_checksum::integer-signed, rest::binary>>, %{frame_state: :frame_length_checksum, frame_length: length} = state) do
    checksum_success = checksum_length(length, length_checksum)
    Logger.debug("Length Checksum: #{checksum_success}")
    if checksum_success do
      process_data(processed_frame, rest, %{state | frame_state: :frame_identifier_and_data})
    else
      process_data(<<>>, rest, %{state | frame_state: :preamble})
    end
  end

  defp process_data(processed_frame, <<rest::binary>>, %{frame_state: :frame_identifier_and_data, frame_length: 0} = state) do
    Logger.debug("Data length: 0")
    process_data(processed_frame, rest, %{state | frame_state: :message_checksum})
  end

  defp process_data(processed_frame, <<message::binary-size(1), rest::binary>>, %{frame_state: :frame_identifier_and_data, frame_length: frame_length} = state) do
    Logger.debug("Data length: #{frame_length}")
    process_data(processed_frame <> message, rest, %{state | frame_state: :frame_identifier_and_data, frame_length: frame_length - 1})
  end

  defp process_data(processed_frame, <<message_checksum::integer-unsigned, rest::binary>>, %{frame_state: :message_checksum} = state) do
    checksum_success = checksum_data(processed_frame, message_checksum)
    Logger.debug("Data Checksum Result: #{checksum_success}")
    process_data(processed_frame, rest, %{state | frame_state: :postamble})
  end

  defp process_data(processed_frame, <<@postamble, rest::binary>>, %{frame_state: :postamble, frames: frames} = state) do
    process_data(<<>>, rest, %{state | frame_state: :preamble, frames: [processed_frame | frames]})
  end

  defp process_data(processed_frame, <<rubbish::binary-size(1), rest::binary>>, state) do
    Logger.warn("Ignoring rubbish data: #{rubbish}")
    process_data(processed_frame, rest, state)
  end

  defp process_data(processed_frame, to_process, %{frame_state: frame_state}) do
    Logger.debug("Unknown data: #{inspect to_process}, #{inspect frame_state}, frame: #{inspect processed_frame}, data: #{inspect to_process}")
  end
end