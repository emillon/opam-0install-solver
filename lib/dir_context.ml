type rejection = UserConstraint of OpamFormula.atom

let ( / ) = Filename.concat

let with_dir path fn =
  let ch = Unix.opendir path in
  Fun.protect ~finally:(fun () -> Unix.closedir ch)
    (fun () -> fn ch)

let list_dir path =
  let rec aux acc ch =
    match Unix.readdir ch with
    | name -> aux (name :: acc) ch
    | exception End_of_file -> acc
  in
  with_dir path (aux [])

type t = {
  env : string -> OpamVariable.variable_contents option;
  packages_dir : string;
  pins : (OpamPackage.Version.t * OpamFile.OPAM.t) OpamPackage.Name.Map.t;
  constraints : OpamFormula.version_constraint OpamTypes.name_map;    (* User-provided constraints *)
  test : OpamPackage.Name.Set.t;
}

let load t pkg =
  let { OpamPackage.name; version = _ } = pkg in
  match OpamPackage.Name.Map.find_opt name t.pins with
  | Some (_, opam) -> opam
  | None ->
    let opam_path = t.packages_dir / OpamPackage.Name.to_string name / OpamPackage.to_string pkg / "opam" in
    OpamFile.OPAM.read (OpamFile.make (OpamFilename.raw opam_path))

let user_restrictions t name =
  OpamPackage.Name.Map.find_opt name t.constraints

let dev = OpamPackage.Version.of_string "dev"

let std_env ~arch ~os ~os_distribution ~os_family ~os_version = function
  | "arch" -> Some (OpamTypes.S arch)
  | "os" -> Some (OpamTypes.S os)
  | "os-distribution" -> Some (OpamTypes.S os_distribution)
  | "os-version" -> Some (OpamTypes.S os_version)
  | "os-family" -> Some (OpamTypes.S os_family)
  | v ->
    OpamConsole.warning "Unknown variable %S" v;
    None

let env t pkg v =
  if List.mem v OpamPackageVar.predefined_depends_variables then None
  else match OpamVariable.Full.to_string v with
    | "version" -> Some (OpamTypes.S (OpamPackage.Version.to_string (OpamPackage.version pkg)))
    | x -> t.env x

let filter_deps t pkg f =
  let dev = OpamPackage.Version.compare (OpamPackage.version pkg) dev = 0 in
  let test = OpamPackage.Name.Set.mem (OpamPackage.name pkg) t.test in
  f
  |> OpamFilter.partial_filter_formula (env t pkg)
  |> OpamFilter.filter_deps ~build:true ~post:true ~test ~doc:false ~dev ~default:false

let candidates t name =
  match OpamPackage.Name.Map.find_opt name t.pins with
  | Some (version, _) -> [version, None]
  | None ->
    match list_dir (t.packages_dir / OpamPackage.Name.to_string name) with
    | versions ->
      let user_constraints = user_restrictions t name in
      versions
      |> List.filter_map (fun dir ->
          match OpamPackage.of_string_opt dir with
          | Some pkg -> Some (OpamPackage.version pkg)
          | None -> None
        )
      |> List.sort (fun a b -> OpamPackage.Version.compare b a)
      |> List.map (fun v ->
          match user_constraints with
          | Some test when not (OpamFormula.check_version_formula (OpamFormula.Atom test) v) ->
            v, Some (UserConstraint (name, Some test))  (* Reject *)
          | _ -> v, None
        )
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      OpamConsole.log "opam-0install" "Package %S not found!" (OpamPackage.Name.to_string name);
      []

let pp_rejection f = function
  | UserConstraint x -> Fmt.pf f "Rejected by user-specified constraint %s" (OpamFormula.string_of_atom x)

let create ?(test=OpamPackage.Name.Set.empty) ?(pins=OpamPackage.Name.Map.empty) ~constraints ~env packages_dir =
  { env; packages_dir; pins; constraints; test }
