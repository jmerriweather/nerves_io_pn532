defmodule Nerves.IO.PN532.Frames do
  use Bitwise

  defmacro iso_14443_type_a_target(target_number, sens_res, sel_res, identifier) do
    quote do
      <<
        unquote(target_number)::integer-signed,
        unquote(sens_res)::binary-size(2),
        unquote(sel_res)::binary-size(1),
        id_length::integer-signed,
        unquote(identifier)::binary-size(id_length)
      >>
    end
  end

  defmacro firmware_version_response(ic_version, version, revision, support) do
    quote do
      <<
        0xD5, 0x03,
        unquote(ic_version)::binary-size(1),
        unquote(version)::integer-signed,
        unquote(revision)::integer-signed,
        unquote(support)::integer-signed
      >>
    end
  end

  def build_command_frame(tfi, command) do
      length = byte_size(command)
      combined_length = length + 1
      lcs = ~~~combined_length + 1
      dsc_checksum = checksum(tfi <> command)
      dsc = ~~~dsc_checksum + 1
      command_frame(<<0x00>>, <<0x00>>, <<0xFF>>, length, combined_length, lcs, tfi, command, dsc, <<0x00>>)
  end

  def command_frame(preamble, startcode1, startcode2, length, combined_length, lcs, tfi, command, dsc, postamble) do
      <<
        preamble::binary-size(1),
        startcode1::binary-size(1),
        startcode2::binary-size(1),
        combined_length::integer-signed,
        lcs::integer-unsigned,
        tfi::binary-size(1),
        command::binary-size(length),
        dsc::integer-unsigned,
        postamble::binary-size(1)
      >>
  end

  def checksum(data), do: checksum(data, 0)
  def checksum(<<head, rest::bitstring>>, acc), do: checksum(rest, head + acc)
  def checksum(<<>>, acc), do: acc

end
