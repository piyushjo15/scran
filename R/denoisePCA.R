#' Denoise expression with PCA
#'
#' Denoise log-expression data by removing principal components corresponding to technical noise.
#'
#' @param x 
#' For \code{getDenoisedPCs}, a numeric matrix of log-expression values, where rows are genes and columns are cells.
#' Alternatively, a \linkS4class{SummarizedExperiment} object containing such a matrix.
#'
#' For \code{denoisePCA}, a \linkS4class{SingleCellExperiment} object containing a log-expression amtrix.
#' @param technical An object containing the technical components of variation for each gene in \code{x}.
#' This can be: 
#' \itemize{
#' \item a function that computes the technical component of the variance for a gene with a given mean log-expression, 
#' as generated by \code{\link{fitTrendVar}}.
#' \item a numeric vector of length equal to the number of rows in \code{x},
#' containing the technical component for each gene. 
#' \item a \linkS4class{DataFrame} of variance decomposition results generated by \code{\link{modelGeneVarWithSpikes}} or related functions.
#' }
#' @param subset.row See \code{?"\link{scran-gene-selection}"}.
#' @param value String specifying the type of value to return.
#' \code{"pca"} will return the PCs, \code{"n"} will return the number of retained components, 
#' and \code{"lowrank"} will return a low-rank approximation.
#' @param min.rank,max.rank Integer scalars specifying the minimum and maximum number of PCs to retain.
#' @param fill.missing Logical scalar indicating whether entries in the rotation matrix should be imputed
#' for genes that were not used in the PCA.
#' @param BSPARAM A \linkS4class{BiocSingularParam} object specifying the algorithm to use for PCA.
#' @param BPPARAM A \linkS4class{BiocParallelParam} object to use for parallel processing.
#' @param ... For the \code{getDenoisedPCs} generic, further arguments to pass to specific methods.
#' For the SingleCellExperiment method, further arguments to pass to the ANY method.
#'
#' For the \code{denoisePCA} function, further arguments to pass to the \code{getDenoisedPCs} function.
#' @param assay.type A string specifying which assay values to use.
#' @param var.exp A numeric vector of the variances explained by successive PCs, starting from the first (but not necessarily containing all PCs).
#' @param var.tech A numeric scalar containing the variance attributable to technical noise.
#' @param var.total A numeric scalar containing the total variance in the data.
#' 
#' @return
#' For \code{getDenoisedPCs}, a list is returned containing:
#' \itemize{
#' \item \code{components}, a numeric matrix containing the selected PCs (columns) for all cells (rows).
#' This has number of columns between \code{min.rank} and \code{max.rank} inclusive.
#' \item \code{rotation}, a numeric matrix containing rotation vectors (columns) for all genes (rows).
#' This has number of columns between \code{min.rank} and \code{max.rank} inclusive.
#' \item \code{percent.var}, a numeric vector containing the percentage of variance explained by the first \code{max.rank} PCs.
#' }
#' 
#' \code{denoisePCA} will return a modified \code{x} with:
#' \itemize{
#' \item the PC results stored in the \code{\link{reducedDims}} as a \code{"PCA"} entry, if \code{type="pca"}.
#' \item a low-rank approximation stored as a new \code{"lowrank"} assay, if \code{type="lowrank"}.
#' }
#' 
#' \code{denoisePCANumber} will return an integer scalar specifying the number of PCs to retain.
#' This is equivalent to the output from \code{getDenoisedPCs} after setting \code{value="n"}, but ignoring any setting of \code{min.rank} or \code{max.rank}.
#' 
#' @details
#' This function performs a principal components analysis to eliminate random technical noise in the data.
#' Random noise is uncorrelated across genes and should be captured by later PCs, as the variance in the data explained by any single gene is low.
#' In contrast, biological processes should be captured by earlier PCs as more variance can be explained by the correlated behavior of sets of genes in a particular pathway. 
#' The idea is to discard later PCs to remove noise and improve resolution of population structure.
#' This also has the benefit of reducing computational work for downstream steps.
#' 
#' The choice of the number of PCs to discard is based on the estimates of technical variance in \code{technical}.
#' This argument accepts a number of different values, depending on how the technical noise is calculated - this generally involves functions such as \code{\link{modelGeneVarWithSpikes}} or \code{\link{modelGeneVarByPoisson}}.
#' The percentage of variance explained by technical noise is estimated by summing the technical components across genes and dividing by the summed total variance.
#' Genes with negative biological components are ignored during downstream analyses to ensure that the total variance is greater than the overall technical estimate. 
#' 
#' Now, consider the retention of the first \eqn{d} PCs.
#' For a given value of \eqn{d}, we compute the variance explained by all of the later PCs.
#' We aim to find the smallest value of \eqn{d} such that the sum of variances explained by the later PCs is still less than the variance attributable to technical noise.
#' This choice of \eqn{d} represents a lower bound on the number of PCs that can be retained before biological variation is definitely lost.
#' We use this value to obtain a \dQuote{reasonable} dimensionality for the PCA output.
#' 
#' Note that \eqn{d} will be coerced to lie between \code{min.rank} and \code{max.rank}.
#' This mitigates the effect of occasional extreme results when the percentage of noise is very high or low.
#'
#' @section Effects of gene selection:
#' We can use \code{subset.row} to perform the PCA on a subset of genes, e.g., HVGs.
#' This can be used to only perform the PCA on genes with the largest biological components,
#' thus increasing the signal-to-noise ratio of downstream analyses.
#' Note that only rows with positive components are actually used in the PCA, 
#' even if we explicitly specified them in \code{subset.row}.
#'
#' If \code{fill.missing=TRUE}, entries of the rotation matrix are imputed for all genes in \code{x}.
#' This includes \dQuote{unselected} genes, i.e., with negative biological components or that were not selected with \code{subset.row}.
#' Rotation vectors are extrapolated to these genes by projecting their expression profiles into the low-dimensional space defined by the SVD on the selected genes.
#' This is useful for guaranteeing that any low-rank approximation has the same dimensions as the input \code{x}.
#' For example, \code{denoisePCA} will only ever use \code{fill.missing=TRUE} when \code{value="lowrank"}.
#'
#' @section Caveats with interpretation:
#' The function's choice of \eqn{d} is only optimal if the early PCs capture all the biological variation with minimal noise.
#' This is unlikely to be true as the PCA cannot distinguish between technical noise and weak biological signal in the later PCs.
#' In practice, the chosen \eqn{d} can only be treated as a lower bound for the retention of signal, and it is debatable whether this has any particular relation to the \dQuote{best} choice of the number of PCs.
#' For example, many aspects of biological variation are not that interesting (e.g., transcriptional bursting, metabolic fluctuations) and it is often the case that we do not need to retain this signal, in which case the chosen \eqn{d} - despite being a lower bound - may actually be higher than necessary.
#'
#' Interpretation of the choice of \eqn{d} is even more complex if \code{technical} was generated with \code{\link{modelGeneVar}} rather than \code{\link{modelGeneVarWithSpikes}} or \code{\link{modelGeneVarByPoisson}}.
#' The former includes \dQuote{uninteresting} biological variation in its technical component estimates, increasing the proportion of variance attributed to technical noise and yielding a lower value of \eqn{d}.
#' Indeed, use of results from \code{\link{modelGeneVar}} often results in \eqn{d} being set to to \code{min.rank}, which can be problematic if secondary factors of biological variation are discarded.
#'
#' % We could still use modelGeneVar() results as technical= but the outcome is difficult to predict.
#' % For example, the difference between uninteresting biological variation and technical noise is that the former is not random.
#' % This means that the assumption that they occupy later PCs may not be entirely true.
#' % One can easily imagine a situation where fluctuations within a large population take precedence over the variation introduced by a small distinct subpopulation.
#'
#' @author
#' Aaron Lun
#' 
#' @seealso
#' \code{\link{modelGeneVarWithSpikes}} and \code{\link{modelGeneVarByPoisson}}, for methods of computing technical components.
#' 
#' \code{\link{runSVD}}, for the underlying SVD algorithm(s).
#' 
#' @examples
#' library(scater)
#' sce <- mockSCE()
#' sce <- logNormCounts(sce)
#' 
#' # Modelling the variance:
#' var.stats <- modelGeneVar(sce)
#' 
#' # Denoising:
#' pcs <- getDenoisedPCs(sce, technical=var.stats)
#' head(pcs$components)
#' head(pcs$rotation)
#' head(pcs$percent.var)
#'
#' # Automatically storing the results.
#' sce <- denoisePCA(sce, technical=var.stats)
#' reducedDimNames(sce)
#' @references
#' Lun ATL (2018).
#' Discussion of PC selection methods for scRNA-seq data.
#' \url{https://github.com/LTLA/PCSelection2018}
#'
#' @name denoisePCA
NULL

#' @importFrom DelayedArray DelayedArray getAutoBPPARAM setAutoBPPARAM
#' @importFrom DelayedMatrixStats rowVars rowMeans2
#' @importClassesFrom S4Vectors DataFrame
#' @importFrom methods is
#' @importFrom BiocParallel SerialParam
#' @importFrom BiocSingular bsparam
#' @importFrom Matrix t
#' @importFrom scater .subset2index
.get_denoised_pcs <- function(x, technical, subset.row=NULL, min.rank=5, max.rank=50, 
    fill.missing=FALSE, BSPARAM=bsparam(), BPPARAM=SerialParam())
# Performs PCA and chooses the number of PCs to keep based on the technical noise.
# This is done on the residuals if a design matrix is supplied.
#
# written by Aaron Lun
# created 13 March 2017    
{
    old <- getAutoBPPARAM()
    setAutoBPPARAM(BPPARAM)
    on.exit(setAutoBPPARAM(old))

    subset.row <- .subset2index(subset.row, x, byrow=TRUE)
    x2 <- DelayedArray(x)
    all.var <- rowVars(x2, rows=subset.row)

    # Processing different mechanisms through which we specify the technical component.
    if (is(technical, "DataFrame")) { 
        # Making sure everyone has the reported total variance.
        total.var <- technical$total[subset.row] 
        scale <- all.var/total.var
        tech.var <- technical$tech[subset.row] * scale
        tech.var[all.var==0 & total.var==0] <- 0
        tech.var[all.var!=0 & total.var==0] <- Inf
    } else {
        if (is.function(technical)) {
            all.means <- rowMeans2(x2, rows=subset.row)
            tech.var <- technical(all.means)
        } else {
            tech.var <- technical[subset.row]
        }
    }

    # Filtering out genes with negative biological components.
    keep <- all.var > tech.var
    tech.var <- tech.var[keep]
    all.var <- all.var[keep]
    use.rows <- subset.row[keep]
    y <- x[use.rows,,drop=FALSE] 

    # Setting up the SVD results. 
    svd.out <- .centered_SVD(t(y), max.rank, keep.left=TRUE, keep.right=TRUE,
        BSPARAM=BSPARAM, BPPARAM=BPPARAM)

    # Choosing the number of PCs.
    var.exp <- svd.out$d^2 / (ncol(y) - 1)
    total.var <- sum(all.var)
    npcs <- denoisePCANumber(var.exp, sum(tech.var), total.var)
    npcs <- .keep_rank_in_range(npcs, min.rank, length(var.exp))

    list(
        components=.svd_to_pca(svd.out, npcs), 
        rotation=.svd_to_rot(svd.out, npcs, x, use.rows, fill.missing),
        percent.var=var.exp/total.var*100
    )
} 

.svd_to_rot <- function(svd.out, ncomp, original.mat, subset.row, fill.missing) {
    ix <- seq_len(ncomp)
    V <- svd.out$v[,ix,drop=FALSE]
    if (is.null(subset.row) || !fill.missing) {
        rownames(V) <- rownames(original.mat)[subset.row]
        return(V)
    }

    U <- svd.out$u[,ix,drop=FALSE]
    D <- svd.out$d[ix]

    fullV <- matrix(0, nrow(original.mat), ncomp)
    rownames(fullV) <- rownames(original.mat)
    colnames(fullV) <- colnames(V)
    fullV[subset.row,] <- V

    # The idea is that after our SVD, we have X=UDV' where each column of X is a gene.
    # Leftover genes are new columns in X, which are projected on the space of U by doing U'X.
    # This can be treated as new columns in DV', which can be multiplied by U to give denoised values.
    # I've done a lot of implicit transpositions here, hence the code does not tightly follow the logic above.
    leftovers <- !logical(nrow(original.mat))
    leftovers[subset.row] <- FALSE

    left.x <- original.mat[leftovers,,drop=FALSE] 
    left.x <- as.matrix(left.x %*% U) - outer(rowMeans(left.x), colSums(U))

    fullV[leftovers,] <- sweep(left.x, 2, D, "/", check.margin=FALSE)

    fullV
}

##############################
# S4 method definitions here #
##############################

#' @export
#' @rdname denoisePCA
setGeneric("getDenoisedPCs", function(x, ...) standardGeneric("getDenoisedPCs"))

#' @export
#' @rdname denoisePCA
setMethod("getDenoisedPCs", "ANY", .get_denoised_pcs)

#' @export
#' @rdname denoisePCA
#' @importFrom SummarizedExperiment assay
setMethod("getDenoisedPCs", "SummarizedExperiment", function(x, ..., assay.type="logcounts") {
    .get_denoised_pcs(assay(x, assay.type), ...)
})

#' @export
#' @rdname denoisePCA
#' @importFrom SummarizedExperiment assay "assay<-"
#' @importFrom SingleCellExperiment reducedDim<- 
denoisePCA <- function(x, ..., value=c("pca", "lowrank"), assay.type="logcounts")
{
    value <- match.arg(value) 
    pcs <- .get_denoised_pcs(assay(x, i=assay.type), ..., fill.missing=(value=="lowrank"))

    if (value=="pca"){ 
        out <- pcs$components
    } else {
        out <- tcrossprod(pcs$rotation, pcs$components)
    }
    attr(out, "percentVar") <- pcs$percent.var

    value <- match.arg(value) 
    if (value=="pca"){ 
        reducedDim(x, "PCA") <- out
    } else if (value=="lowrank") {
        assay(x, i="lowrank") <- out
    }
    x
}

#' @export
#' @rdname denoisePCA
denoisePCANumber <- function(var.exp, var.tech, var.total) 
# Discarding PCs until we get rid of as much technical noise as possible
# while preserving the biological signal. This is done by assuming that 
# the biological signal is fully contained in earlier PCs, such that we 
# discard the later PCs until we account for 'var.tech'.
{
    npcs <- length(var.exp)
    flipped.var.exp <- rev(var.exp)
    estimated.contrib <- cumsum(flipped.var.exp) + (var.total - sum(flipped.var.exp)) 

    above.noise <- estimated.contrib > var.tech 
    if (any(above.noise)) { 
        to.keep <- npcs - min(which(above.noise)) + 1L
    } else {
        to.keep <- 1L
    }

    to.keep
}
