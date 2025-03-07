# docs

docs are hosted and served by docusaurus in `/src/docs/docusaurus/`.

to allows us to keep the documentation
close to the code while also allowing for a single source of truth
(e.g., `docusaurus/docs/code/accountsdb.md` and `src/accountsdb/readme.md`),
we use `generate.py` to copy the document stored in the `src` folder to the
`docusaurus/docs/code` folder.

**note**: make sure all modifications are made in the `SRC/` folder and then run
`generate.py` to copy the files to the `docusaurus/` folder. changes made in the
`docusaurus/` folder will be overwritten.

## usage

to generate the docs, run:

```bash
python generate.py
```

*note:* you need to run this command from the docs/ directory.

to check to see if all changes are up to date, run:

```bash
python docs/check.py ./ # from the src/ directory
# or
python check.py ../ # from the src/docs directory
```

*note:* this command is run during the CI/CD pipeline to ensure that the docs are up to date.

## docs formatting

to ensure that the markdown is formatted correctly, we use the following
conventions:
- '#' for headers which will correspond to the title and sidebar name in docusaurus
- all images need to point to /docs/docusaurus/static/img/

## exclusion

to exclude a markdown file, insert a line with "docs: exclude\n" anywhere in the file.
