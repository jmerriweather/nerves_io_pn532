defmodule Nerves.IO.PN532.Frames do

  defmacro in_list_passive_target_card(target_number, sens_res, sel_res, identifier) do
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

  defmacro get_firmware_version_response(ic_version, version, revision, support) do
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
  
  defmacro build_command_frame(tfi, command) do    
    quote do
      length = byte_size(unquote(command))
      combined_length = length + 1
      lcs = ~~~combined_length + 1
      dsc_checksum = checksum(unquote(tfi) <> unquote(command))
      dsc = ~~~dsc_checksum + 1
      command_frame(<<0x00>>, <<0x00>>, <<0xFF>>, length, combined_length, lcs, unquote(tfi), unquote(command), dsc, <<0x00>>)
    end
  end

  defmacro command_frame(preamble, startcode1, startcode2, length, combined_length, lcs, tfi, command, dsc, postamble) do
    quote do
      <<
        unquote(preamble)::binary-size(1), 
        unquote(startcode1)::binary-size(1), 
        unquote(startcode2)::binary-size(1), 
        unquote(combined_length)::integer-signed, 
        unquote(lcs)::integer-signed, 
        unquote(tfi)::binary-size(1), 
        unquote(command)::binary-size(unquote(length)), 
        unquote(dsc)::integer-signed, 
        unquote(postamble)::binary-size(1)
      >>
    end
  end

  def checksum(data), do: checksum(:erlang.iolist_to_binary(data), 0)
  def checksum(<<head, rest::binary>>, acc), do: checksum(rest, head + acc)
  def checksum(<<>>, acc), do: acc

end