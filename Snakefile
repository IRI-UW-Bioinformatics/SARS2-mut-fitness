"""Top-level ``snakemake`` file that runs pipeline."""


import textwrap

import pandas as pd

import yaml


configfile: "config.yaml"

with open(config["docs_plot_annotations"]) as f:
    docs_plot_annotations = yaml.safe_load(f)


rule all:
    """Target rule with desired output files."""
    input:
        "results/expected_vs_actual_mut_counts/expected_vs_actual_mut_counts.csv",
        "results/aa_fitness/aamut_fitness_all.csv",
        "results/aa_fitness/aamut_fitness_by_clade.csv",
        "results/aa_fitness/aamut_fitness_by_subset.csv",
        "results/aa_fitness/aa_fitness.csv",
        expand("docs/{plot}.html", plot=docs_plot_annotations["plots"]),
        "docs/index.html",
        "results/dca/dca_corr.pdf",


rule get_mat_tree:
    """Get the pre-built mutation-annotated tree."""
    params:
        url=config["mat_tree"],
    output:
        mat="results/mat/mat_tree.pb.gz"
    shell:
        "curl {params.url} > {output.mat}"


rule get_ref_fasta:
    """Get the reference FASTA."""
    params:
        url=config["ref_fasta"],
    output:
        ref_fasta="results/ref/ref.fa",
    shell:
        "wget -O - {params.url} | gunzip -c > {output.ref_fasta}"


rule get_ref_gtf:
    """Get the reference FASTA."""
    params:
        url=config["ref_gtf"],
    output:
        ref_gtf="results/ref/ref.gtf",
    shell:
        "wget -O - {params.url} | gunzip -c > {output.ref_gtf}"


rule get_dca_data:
    """Get DCA data to use as comparator."""
    params:
        url="https://raw.githubusercontent.com/GiancarloCroce/DCA_SARS-CoV-2/main/data/data_dca_proteome.csv"
    output:
        csv="results/dca/dca_mutability.csv"
    shell:
        "curl {params.url} -o {output}"


rule ref_coding_sites:
    """Get all sites in reference that are part of a coding sequence."""
    input:
        gtf=rules.get_ref_gtf.output.ref_gtf
    output:
        csv="results/ref/coding_sites.csv",
    script:
        "scripts/ref_coding_sites.py"


checkpoint mat_samples:
    """Get all samples in mutation-annotated tree with their dates and clades."""
    input:
        mat=rules.get_mat_tree.output.mat,
    output:
        csv="results/mat/samples.csv",
        clade_counts="results/mat/sample_clade_counts.csv",
    params:
        min_clade_samples=config["min_clade_samples"],
    script:
        "scripts/mat_samples.py"


def clades_w_adequate_counts(wc):
    """Return list of all clades with adequate sample counts."""
    return (
        pd.read_csv(checkpoints.mat_samples.get(**wc).output.clade_counts)
        .query("adequate_sample_counts")
        ["nextstrain_clade"]
        .tolist()
    )


rule samples_by_clade_subset:
    """Get samples in mutation-annotated tree by nextstrain clade and subset."""
    input:
        csv=rules.mat_samples.output.csv,
    output:
        txt="results/mat_by_clade_subset/{clade}_{subset}.txt",
    params:
        match_regex=lambda wc: config["sample_subsets"][wc.subset]
    run:
        (
            pd.read_csv(input.csv)
            .query("nextstrain_clade == @wildcards.clade")
            .query(f"sample.str.match('{params.match_regex}')")
            ["sample"]
            .to_csv(output.txt, index=False, header=False)
        )


rule mat_clade_subset:
    """Get mutation-annotated tree for just a clade and subset."""
    input:
        mat=rules.get_mat_tree.output.mat,
        samples=rules.samples_by_clade_subset.output.txt,
    output:
        mat="results/mat_by_clade_subset/{clade}_{subset}.pb",
    shell:
        """
        if [ -s {input.samples} ]; then
            echo "Extracting samples from {input.samples}"
            matUtils extract -i {input.mat} -s {input.samples} -O -o {output.mat}
        else
            echo "No samples in {input.samples}"
            touch {output.mat}
        fi
        """


rule translate_mat:
    """Translate mutations on mutation-annotated tree for clade."""
    input:
        mat=rules.mat_clade_subset.output.mat,
        ref_fasta=rules.get_ref_fasta.output.ref_fasta,
        ref_gtf=rules.get_ref_gtf.output.ref_gtf,
    output:
        tsv="results/mat_by_clade_subset/{clade}_{subset}_mutations.tsv",
    shell:
        """
        matUtils summary \
            -i {input.mat} \
            -g {input.ref_gtf} \
            -f {input.ref_fasta} \
            -t {output.tsv}
        """


rule clade_founder_json:
    """Get JSON with nexstrain clade founders (indels not included)."""
    params:
        url=config["clade_founder_json"],
    output:
        json="results/clade_founders_no_indels/clade_founders.json",
    shell:
        "curl {params.url} > {output.json}"


rule clade_founder_fasta_and_muts:
    """Get FASTA and mutations for nextstrain clade founder (indels not included)."""
    input:
        json=rules.clade_founder_json.output.json,
        ref_fasta=rules.get_ref_fasta.output.ref_fasta,
    output:
        fasta="results/clade_founders_no_indels/{clade}.fa",
        muts="results/clade_founders_no_indels/{clade}_ref_to_founder_muts.csv",
    script:
        "scripts/clade_founder_fasta.py"


rule site_mask_vcf:
    """Get the site mask VCF."""
    output:
        vcf="results/site_mask/site_mask.vcf",
    params:
        url=config["site_mask_vcf"],
    shell:
        "curl {params.url} > {output.vcf}"


rule site_mask:
    """Convert site mask VCF to CSV."""
    input:
        vcf=rules.site_mask_vcf.output.vcf,
    output:
        csv="results/site_mask/site_mask.csv",
    script:
        "scripts/site_mask.py"


rule count_mutations:
    """Count mutations, excluding branches with too many mutations or reversions."""
    input:
        tsv=rules.translate_mat.output.tsv,
        ref_fasta=rules.get_ref_fasta.output.ref_fasta,
        clade_founder_fasta=rules.clade_founder_fasta_and_muts.output.fasta,
        ref_to_founder_muts=rules.clade_founder_fasta_and_muts.output.muts,
        usher_masked_sites=config["usher_masked_sites"],
        site_mask=rules.site_mask.output.csv,
    output:
        csv="results/mutation_counts/{clade}_{subset}.csv",
    params:
        max_nt_mutations=config["max_nt_mutations"],
        max_reversions_to_ref=config["max_reversions_to_ref"],
        max_reversions_to_clade_founder=config["max_reversions_to_clade_founder"],
        exclude_ref_to_founder_muts=config["exclude_ref_to_founder_muts"],
        sites_to_exclude=config["sites_to_exclude"],
    log:
        notebook="results/mutation_counts/{clade}_{subset}_count_mutations.ipynb",
    notebook:
        "notebooks/count_mutations.py.ipynb"


rule clade_founder_nts:
    """Get nucleotide at each coding site for clade founders."""
    input:
        coding_sites=rules.ref_coding_sites.output.csv,
        fastas=lambda wc: [
            f"results/clade_founders_no_indels/{clade}.fa"
            for clade in clades_w_adequate_counts(wc)
        ],
    output:
        csv="results/clade_founder_nts/clade_founder_nts.csv",
    script:
        "scripts/clade_founder_nts.py"


rule aggregate_mutation_counts:
    """Aggregate the mutation counts for all clades and subsets."""
    input:
        clade_founder_nts=rules.clade_founder_nts.output.csv,
        counts=lambda wc: [
            f"results/mutation_counts/{clade}_{subset}.csv"
            for clade in clades_w_adequate_counts(wc)
            for subset in config["sample_subsets"]
        ],
    output:
        csv="results/mutation_counts/aggregated.csv",
    script:
        "scripts/aggregate_mutation_counts.py"


rule synonymous_mut_rates:
    """Compute and analyze rates and spectra of synonymous mutations."""
    input:
        mutation_counts_csv=rules.aggregate_mutation_counts.output.csv,
        clade_founder_nts_csv=rules.clade_founder_nts.output.csv,
        nb="notebooks/synonymous_mut_rates.ipynb",
    output:
        rates_by_clade="results/synonymous_mut_rates/rates_by_clade.csv",
        nb="results/synonymous_mut_rates/synonymous_mut_rates.ipynb",
        nb_html="results/synonymous_mut_rates/synonymous_mut_rates.html",
        rates_plot="results/synonymous_mut_rates/mut_rates.html",
    params:
        config["synonymous_spectra_min_counts"],
        config['sample_subsets'],
        config["clade_synonyms"],
    shell:
        """
        papermill {input.nb} {output.nb} \
            -p mutation_counts_csv {input.mutation_counts_csv} \
            -p clade_founder_nts_csv {input.clade_founder_nts_csv} \
            -p rates_by_clade_csv {output.rates_by_clade} \
            -p rates_plot {output.rates_plot}
        jupyter nbconvert {output.nb} --to html
        """


rule expected_mut_counts:
    """Compute expected mutation counts from synonymous mutation rates and counts."""
    input:
        rates_by_clade=rules.synonymous_mut_rates.output.rates_by_clade,
        clade_founder_nts_csv=rules.clade_founder_nts.output.csv,
        nb="notebooks/expected_mut_counts.ipynb",
    output:
        expected_counts="results/expected_mut_counts/expected_mut_counts.csv",
        nb="results/expected_mut_counts/expected_mut_counts.ipynb",
        nb_html="results/expected_mut_counts/expected_mut_counts.html",
    shell:
        """
        papermill {input.nb} {output.nb} \
            -p clade_founder_nts_csv {input.clade_founder_nts_csv} \
            -p rates_by_clade_csv {input.rates_by_clade} \
            -p expected_counts_csv {output.expected_counts}
        jupyter nbconvert {output.nb} --to html
        """


rule aggregate_mutations_to_exclude:
    """Aggregate the set of all mutations to exclude for each clade."""
    input:
        muts_to_exclude=lambda wc: [
            f"results/clade_founders_no_indels/{clade}_ref_to_founder_muts.csv"
            for clade in clades_w_adequate_counts(wc)
        ],
        usher_masked_sites=config["usher_masked_sites"],
        site_mask=rules.site_mask.output.csv,
    output:
        csv="results/expected_vs_actual_mut_counts/mutations_to_exclude.csv",
    params:
        clades=lambda wc: clades_w_adequate_counts(wc),
        sites_to_exclude=config["sites_to_exclude"],
        exclude_ref_to_founder_muts=config["exclude_ref_to_founder_muts"],
    script:
        "scripts/aggregate_mutations_to_exclude.py"


rule merge_expected_and_actual_counts:
    """Merge expected and actual counts."""
    input:
        expected=rules.expected_mut_counts.output.expected_counts,
        actual=rules.aggregate_mutation_counts.output.csv,
        muts_to_exclude=rules.aggregate_mutations_to_exclude.output.csv,
    output:
        csv="results/expected_vs_actual_mut_counts/expected_vs_actual_mut_counts.csv",
    log:
        notebook="results/expected_vs_actual_mut_counts/merge_expected_and_actual_counts.ipynb",
    notebook:
        "notebooks/merge_expected_and_actual_counts.py.ipynb"


rule summarize_expected_vs_actual:
    """Summarize expected vs actual across mutations."""
    input:
        csv=rules.merge_expected_and_actual_counts.output.csv,
    output:
        chart="results/expected_vs_actual_mut_counts/avg_counts.html",
    log:
        notebook="results/expected_vs_actual_mut_counts/summarize_expected_vs_actual.ipynb",
    notebook:
        "notebooks/summarize_expected_vs_actual.py.ipynb"


rule aamut_fitness:
    """Fitness effects from expected vs actual counts for amino-acid mutations."""
    input:
        csv=rules.merge_expected_and_actual_counts.output.csv,
    output:
        aamut_all="results/aa_fitness/aamut_fitness_all.csv",
        aamut_by_clade="results/aa_fitness/aamut_fitness_by_clade.csv",
        aamut_by_subset="results/aa_fitness/aamut_fitness_by_subset.csv",
    params:
        orf1ab_to_nsps=config["orf1ab_to_nsps"],
        fitness_pseudocount=config["fitness_pseudocount"],
    log:
        notebook="results/aa_fitness/aamut_fitness.ipynb",
    notebook:
        "notebooks/aamut_fitness.py.ipynb"


rule aa_fitness:
    """Fitnesses of different amino acids across clades."""
    input:
        aamut_fitness=rules.aamut_fitness.output.aamut_all,
    output:
        aa_fitness="results/aa_fitness/aa_fitness.csv",
    log:
        notebook="results/aa_fitness/aa_fitness.ipynb",
    notebook:
        "notebooks/aa_fitness.py.ipynb"


rule analyze_aa_fitness:
    """Analyze and plot amino-acid mutation fitnesses."""
    input:
        aamut_all=rules.aamut_fitness.output.aamut_all,
        aamut_by_subset=rules.aamut_fitness.output.aamut_by_subset,
        aamut_by_clade=rules.aamut_fitness.output.aamut_by_clade,
        aafitness=rules.aa_fitness.output.aa_fitness,
        clade_founder_nts=rules.clade_founder_nts.output.csv,
    params:
        min_expected_count=config["min_expected_count"],
        clade_corr_min_count=config["clade_corr_min_count"],
        init_ref_clade=config["aa_fitness_init_ref_clade"],
        clade_synonyms=config["clade_synonyms"],
        heatmap_minimal_domain=config["aa_fitness_heatmap_minimal_domain"],
        orf1ab_to_nsps=config["orf1ab_to_nsps"],
    output:
        outdir=directory("results/aa_fitness/plots"),
    log:
        notebook="results/aa_fitness/analyze_aa_fitness.ipynb",
    notebook:
        "notebooks/analyze_aa_fitness.py.ipynb"


rule process_dms_dataset:
    """Process a deep mutational scanning dataset to fitness estimates."""
    input:
        unpack(
            lambda wc: (
                {"wt_seq": config["dms_datasets"][wc.dms_dataset]["wt_seq"]}
                if "wt_seq" in config["dms_datasets"][wc.dms_dataset]
                else {}
            )
        ),
        nb="notebooks/process_{dms_dataset}.ipynb",
    output:
        raw_data="results/dms/{dms_dataset}/raw.csv",
        processed="results/dms/{dms_dataset}/processed.csv",
        nb="results/dms/{dms_dataset}/process_{dms_dataset}.ipynb",
        html="results/dms/{dms_dataset}/process_{dms_dataset}.html",
    params:
        url=lambda wc: config["dms_datasets"][wc.dms_dataset]["url"],
        wt_seq_param=lambda wc, input: (
            f"-p wt_seq_fasta {input.wt_seq}"
            if "wt_seq" in config["dms_datasets"][wc.dms_dataset]
            else ""
        ),
    shell:
        """
        curl {params.url} > {output.raw_data}
        papermill {input.nb} {output.nb} \
            -p raw_data_csv {output.raw_data} \
            {params.wt_seq_param} \
            -p processed_csv {output.processed}
        jupyter nbconvert {output.nb} --to html
        """

rule compare_dca_fitness:
    """Compare to DCA mutability estimates."""
    input:
        dca=rules.get_dca_data.output.csv,
        fitness=rules.aamut_fitness.output.aamut_all,
    output:
        plot="results/dca/dca_corr.pdf",
    script:
        "scripts/compare_dca_fitness.py"


rule fitness_dms_corr:
    """Correlate the fitness estimates with those from deep mutational scanning."""
    input:
        aafitness=rules.aa_fitness.output.aa_fitness,
        neher_fitness=config["neher_fitness"],
        **{
            dms_dataset: f"results/dms/{dms_dataset}/processed.csv"
            for dms_dataset in config["dms_datasets"]
        },
    output:
        plotsdir=directory("results/fitness_dms_corr/plots")
    params:
        min_expected_count=config["min_expected_count"],
        dms_datasets=config["dms_datasets"],
    log:
        notebook="results/fitness_dms_corr/fitness_dms_corr.ipynb",
    notebook:
        "notebooks/fitness_dms_corr.py.ipynb"


rule clade_fixed_muts:
    """Analyze mutations fixed in each clade."""
    input:
        aafitness=rules.aa_fitness.output.aa_fitness,
        aamut_by_clade=rules.aamut_fitness.output.aamut_by_clade,
        clade_founder_nts_csv=rules.clade_founder_nts.output.csv,
    output:
        fixed_muts_chart="results/clade_fixed_muts/clade_fixed_muts.html",
        fixed_muts_hist="results/clade_fixed_muts/clade_fixed_muts_hist.html",
    params:
        min_expected_count=config["min_expected_count"],
        ref=config["clade_fixed_muts_ref"],
        orf1ab_to_nsps=config["orf1ab_to_nsps"],
    log:
        notebook="results/clade_fixed_muts/clade_fixed_muts.ipynb",
    notebook:
        "notebooks/clade_fixed_muts.py.ipynb"


rule fitness_vs_terminal:
    """Analyze fitness effects of mutations vs terminal / non-terminal node counts."""
    input:
        aamut_all=rules.aamut_fitness.output.aamut_all,
    output:
        chart="results/fitness_vs_terminal/fitness_vs_terminal.html",
    params:
        min_expected_count=config["min_expected_count"],
        min_actual_count=config["terminal_min_actual_count"],
        pseudocount=config["terminal_pseudocount"],
    log:
        notebook="results/fitness_vs_terminal/fitness_vs_terminal.ipynb",
    notebook:
        "notebooks/fitness_vs_terminal.py.ipynb"


rule aggregate_plots_for_docs:
    """Aggregate plots to include in GitHub pages docs."""
    input:
        aa_fitness_plots_dir=rules.analyze_aa_fitness.output.outdir,
        dms_corr_plotsdir=rules.fitness_dms_corr.output.plotsdir,
        rates_plot=rules.synonymous_mut_rates.output.rates_plot,
        clade_fixed_muts=rules.clade_fixed_muts.output.fixed_muts_chart,
        clade_fixed_hist=rules.clade_fixed_muts.output.fixed_muts_hist,
        fitness_vs_terminal=rules.fitness_vs_terminal.output.chart,
        avg_counts=rules.summarize_expected_vs_actual.output.chart
    output:
        expand(
            os.path.join("results/plots_for_docs/{plot}.html"),
            plot=docs_plot_annotations["plots"],
        ),
    params:
        plotsdir="results/plots_for_docs",
    shell:
        """
        mkdir -p {params.plotsdir}
        rm -f {params.plotsdir}/*
        cp {input.aa_fitness_plots_dir}/*.html {params.plotsdir}
        cp {input.dms_corr_plotsdir}/*.html {params.plotsdir}
        cp {input.rates_plot} {params.plotsdir}
        cp {input.clade_fixed_muts} {params.plotsdir}
        cp {input.clade_fixed_hist} {params.plotsdir}
        cp {input.fitness_vs_terminal} {params.plotsdir}
        cp {input.avg_counts} {params.plotsdir}
        """


rule format_plot_for_docs:
    """Format a specific plot for the GitHub pages docs."""
    input:
        plot=os.path.join(rules.aggregate_plots_for_docs.params.plotsdir, "{plot}.html"),
        script="scripts/format_altair_html.py",
    output:
        plot="docs/{plot}.html",
        markdown=temp("results/plots_for_docs/{plot}.md"),
    params:
        annotations=lambda wc: docs_plot_annotations["plots"][wc.plot],
        url=os.path.join(config["docs_url"], "{plot}.html"),
        legend_suffix=docs_plot_annotations["legend_suffix"]
    shell:
        """
        echo "## {params.annotations[title]}\n" > {output.markdown}
        echo "{params.annotations[legend]}\n\n" >> {output.markdown}
        echo "{params.legend_suffix}" >> {output.markdown}
        python {input.script} \
            --chart {input.plot} \
            --markdown {output.markdown} \
            --site {params.url} \
            --title "{params.annotations[title]}" \
            --description "{params.annotations[title]}" \
            --output {output.plot}
        """


rule docs_index:
    """Write index for GitHub Pages docs that re-directs to main repo."""
    output:
        html="docs/index.html",
    params:
        docs_url=config["docs_url"],
        plot_annotations=docs_plot_annotations,
    script:
        "scripts/docs_index.py"
