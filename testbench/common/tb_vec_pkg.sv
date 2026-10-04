// tb_vec_pkg -- reads vectors/*.hex (tools/gen_vectors.py) for the testbenches that replay them.
// One line = {gqh_pkg::req_t, gqh_pkg::rsp_t}, 32 hex digits; lines starting with // are comments.
// The expected half of every line comes from tools/oracle.py. Nothing here computes one.
package tb_vec_pkg;
    typedef logic [127:0] vec_t;

    localparam int unsigned N_DEFAULT = 5;
    // Replayed in this order when a test is run without +VEC=<file>: one seed of every profile.
    localparam string DEFAULT_FILES [N_DEFAULT] = '{
        "vectors/organizer_s1.hex", "vectors/judge_s1.hex", "vectors/cross_s1.hex", "vectors/equal_s1.hex", "vectors/extreme_s1.hex"};

    // Appends the file's vectors to q. Returns the number read; 0 means missing or empty file.
    function automatic int unsigned load_vectors(input string path, ref vec_t q [$]);
        int          fd;
        string       line;
        vec_t        v;
        int unsigned n = 0;
        fd = $fopen(path, "r");
        if (fd == 0) return 0;
        while ($fgets(line, fd) > 0) begin
            if (line.len() >= 2 && line.substr(0, 1) == "//") continue;
            if ($sscanf(line, "%h", v) == 1) begin
                q.push_back(v);
                n++;
            end
        end
        $fclose(fd);
        return n;
    endfunction

    // The files a test replays: +VEC=<file> if given, otherwise DEFAULT_FILES.
    function automatic void load_all(ref vec_t q [$]);
        string path;
        if ($value$plusargs("VEC=%s", path)) begin
            if (load_vectors(path, q) == 0) $error("no vectors in %s", path);
        end else begin
            foreach (DEFAULT_FILES[i])
                if (load_vectors(DEFAULT_FILES[i], q) == 0)
                    $error("no vectors in %s: run python tools/gen_vectors.py --profile all --seeds 2", DEFAULT_FILES[i]);
        end
    endfunction
endpackage
