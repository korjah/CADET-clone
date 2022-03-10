// =============================================================================
//  CADET
//  
//  Copyright © 2008-2022: The CADET Authors
//            Please see the AUTHORS and CONTRIBUTORS file.
//  
//  All rights reserved. This program and the accompanying materials
//  are made available under the terms of the GNU Public License v3.0 (or, at
//  your option, any later version) which accompanies this distribution, and
//  is available at http://www.gnu.org/licenses/gpl.html
// =============================================================================

#include <json.hpp>
#include <inja.hpp>

#include <iostream>
#include <sstream>
#include <fstream>
#include <exception>

/**
 * @file Provides a code generator tool using templates.
 * The data file is scanned for blocks enclosed by C++ multiline comment with two additional hash signs,
 * i.e., {slash}*<codegen> and </codegen>*{slash}. Each block is assumed to contain a JSON object that serves as data
 * for an inja template given in a separate file. The blocks are replaced by their template instantiations
 * and the result is written to file.
 * 
 * The template is taken from a file after the marker {slash}* <codegentemplate> *{slash}. If the marker is not
 * found, the full file is taken as template.
 */

/**
 * @brief Reads a file into a string
 * @param [in] fileName Filename
 * @return Contents of the file
 */
std::string readFile(const std::string& fileName)
{
	std::ifstream in(fileName);
    std::ostringstream sstr;
    sstr << in.rdbuf();
    return sstr.str();
}

/**
 * @brief Extracts the template part from a string
 * @details Looks for the marker that defines the beginning of the template. If the marker is not
 *          present, the full string is taken as template.
 * @param [in,out] templateFile Template string that is modified to contain only the template on exit
 * @param [in] markerTemplate Marker for the beginning of the template
 */
void extractTemplate(std::string& templateFile, const std::string& markerTemplate)
{
	typedef typename std::string::size_type size_type;
	const size_type pos = templateFile.find(markerTemplate);
	if (pos == std::string::npos)
		return;

	templateFile = templateFile.substr(pos + markerTemplate.size());
}

/**
 * @brief Processes a data block using a template
 * @details Applies data to the template and inserts the results into the output stream.
 * @param [in] templateFile Template
 * @param [in] dataBlock Data block
 * @param [in,out] output Output stream
 */
void processData(const std::string& templateFile, const std::string& dataBlock, std::ostringstream& output)
{
	nlohmann::json data = nlohmann::json::parse(dataBlock);
	output << inja::render(templateFile, data);
}

int main(int argc, char** argv)
{
	if (argc != 4)
	{
		std::cout << "Usage: templateCodeGen <TemplateFile> <DataFile> <ResultFile>" << std::endl;
		return -1;
	}

	// Define markers
	const int markerSize = 11;
	const int markerEndSize = 12;
	char const* const markerBegin = "/*<codegen>";
	char const* const markerEnd = "</codegen>*/";
	const std::string markerTemplate = "/* <codegentemplate> */";

	// Read files
	const std::string templateFileName = argv[1];
	const std::string dataFileName = argv[2];
	std::string templateFile = "";
	std::string dataFile = "";

	try
	{
		templateFile = readFile(templateFileName);
		dataFile = readFile(dataFileName);
	}
	catch (const std::exception& e)
	{
		std::cerr << "ERROR: " << e.what() << std::endl;
		return -2;
	}

	// Extract template
	extractTemplate(templateFile, markerTemplate);

	// Write disclaimer as header
	std::ostringstream output;
	output << R"header(/***********************************************************
 * DO NOT EDIT. This file was generated by templateCodeGen from
 *   )header" << dataFileName << R"header(
 * using template 
 *   )header" << templateFileName << R"header(
 * Please edit either the data or the applied template.
 **********************************************************/
)header" << "\n";

	// Iterate over all data chunks
	typedef typename std::string::size_type size_type;
	size_type prevEnd = 0;
	size_type pos = dataFile.find(markerBegin);
	while (pos != std::string::npos)
	{
		// Look for end of data chunk
		size_type posEnd = dataFile.find(markerEnd, pos + 1);

		// Found a chunk of data, process it
		if (posEnd != std::string::npos)
		{
			output << dataFile.substr(prevEnd, pos - prevEnd);
			try
			{
				processData(templateFile, dataFile.substr(pos + markerSize, posEnd - pos - markerSize), output);
			}
			catch (nlohmann::json::exception& e)
			{
				std::cerr << "JSON ERROR: " << e.what() << std::endl;
				return -3;
			}
			catch (const std::exception& e)
			{
				std::cerr << "ERROR: " << e.what() << std::endl;
				return -4;
			}
		}

		// Look for next data
		prevEnd = posEnd + markerEndSize;
		pos = dataFile.find(markerBegin, posEnd + 1);
	}
	output << dataFile.substr(prevEnd);

	// Write to file
	std::ofstream outFile(argv[3], std::ios_base::out | std::ios_base::trunc);
	outFile << output.str();

	return 0;
}
