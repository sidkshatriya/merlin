let program_name = ref "Merlin"

let set_program_name name = program_name := name

let program_name () = !program_name

module Json = struct
  let set_pretty_to_string f =
    Std.Json.pretty_to_string := f
end