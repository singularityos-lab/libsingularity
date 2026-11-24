int main(string[] args) {
    try {
        stdout.puts(Singularity.Style.WebTokens.css());
    } catch (Error e) {
        stderr.printf("singularity-web-tokens: %s\n", e.message);
        return 1;
    }
    return 0;
}
